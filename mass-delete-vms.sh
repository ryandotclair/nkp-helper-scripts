#!/bin/bash
set -uo pipefail

# Script to delete powered-off Kubernetes VMs in a specific cluster via Prism Central v3 API.
# Uses same cluster filter as mass-delete-storage.sh (KubernetesClusterName / kubernetes_cluster_name).
# API: DELETE /api/nutanix/v3/vms/{uuid} (returns 202 Accepted).

if [ -f env.vars ]; then
    source env.vars
else
    echo "ERROR: env.vars file not found. Create it and add NUTANIX_ENDPOINT, NUTANIX_USER, NUTANIX_PASSWORD." >&2
    exit 1
fi

CLUSTER_NAME_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --cluster)
            if [ $# -lt 2 ]; then
                echo "ERROR: --cluster requires a value" >&2
                echo "Usage: $0 --cluster <cluster-name>" >&2
                exit 1
            fi
            CLUSTER_NAME_ARG="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 --cluster <cluster-name>" >&2
            exit 1
            ;;
    esac
done

if [ -z "$CLUSTER_NAME_ARG" ]; then
    echo "ERROR: --cluster flag is required" >&2
    echo "Usage: $0 --cluster <cluster-name>" >&2
    exit 1
fi

CLUSTER_NAME="$CLUSTER_NAME_ARG"

NUTANIX_ENDPOINT="${NUTANIX_ENDPOINT:-}"
NUTANIX_USER="${NUTANIX_USER:-admin}"
NUTANIX_PASSWORD="${NUTANIX_PASSWORD:-}"
CURL_TIMEOUT="${CURL_TIMEOUT:-90}"

if [ -z "$NUTANIX_ENDPOINT" ]; then
    echo "ERROR: NUTANIX_ENDPOINT is not set. Set it in env.vars or export it." >&2
    exit 1
fi
if [ -z "$NUTANIX_PASSWORD" ]; then
    echo "ERROR: NUTANIX_PASSWORD is not set. Set it in env.vars or export it." >&2
    exit 1
fi

if [[ "$NUTANIX_ENDPOINT" =~ ^https?://([^:/]+)(:([0-9]+))? ]]; then
    PC_IP="${BASH_REMATCH[1]}"
    PC_PORT="${BASH_REMATCH[3]:-9440}"
elif [[ "$NUTANIX_ENDPOINT" =~ ^([^:/]+)(:([0-9]+))? ]]; then
    PC_IP="${BASH_REMATCH[1]}"
    PC_PORT="${BASH_REMATCH[3]:-9440}"
else
    echo "ERROR: Could not parse NUTANIX_ENDPOINT: $NUTANIX_ENDPOINT" >&2
    exit 1
fi

PC_BASE_URL="https://${PC_IP}:${PC_PORT}"

echo "Connecting to Prism Central: $PC_BASE_URL"
echo "User: $NUTANIX_USER"
echo "Cluster filter: $CLUSTER_NAME"
echo ""

api_call() {
    local method=$1
    local endpoint=$2
    local data=${3:-}
    if [ "$method" = "POST" ]; then
        if [ -n "$data" ]; then
            curl -k -s --max-time "$CURL_TIMEOUT" \
                -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
                -H "Content-Type: application/json" \
                -H "Accept: application/json" \
                -X POST \
                -d "$data" \
                "${PC_BASE_URL}${endpoint}"
        else
            curl -k -s --max-time "$CURL_TIMEOUT" \
                -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
                -H "Content-Type: application/json" \
                -H "Accept: application/json" \
                -X POST \
                "${PC_BASE_URL}${endpoint}"
        fi
    elif [ "$method" = "DELETE" ]; then
        curl -k -s --max-time "$CURL_TIMEOUT" \
            -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
            -H "Accept: application/json" \
            -X DELETE \
            "${PC_BASE_URL}${endpoint}"
    fi
}

echo "Finding powered-off VMs in cluster '$CLUSTER_NAME'..."
VM_LIST_RESPONSE=$(api_call "POST" "/api/nutanix/v3/vms/list" '{"kind":"vm","length":500}')

POWERED_OFF_VMS=$(echo "$VM_LIST_RESPONSE" | jq -c --arg cluster "$CLUSTER_NAME" '
    .entities[]? |
    select(.status.resources.power_state == "OFF") |
    select(
        ((.metadata.categories.KubernetesClusterName // "") == $cluster) or
        ((.metadata.categories.kubernetes_cluster_name // "") == $cluster) or
        ((.spec.categories.KubernetesClusterName // "") == $cluster) or
        ((.spec.categories.kubernetes_cluster_name // "") == $cluster)
    )
')

POWERED_OFF_VM_UUIDS=$(echo "$POWERED_OFF_VMS" | jq -r '.metadata.uuid // empty' | grep -v '^$' | grep -v '^null$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
POWERED_OFF_COUNT=$(echo "$POWERED_OFF_VM_UUIDS" | wc -l | tr -d ' ')

if [ "$POWERED_OFF_COUNT" -eq 0 ]; then
    echo "No powered-off VMs found in cluster '$CLUSTER_NAME'."
    exit 0
fi

echo "Found $POWERED_OFF_COUNT powered-off VM(s) in cluster '$CLUSTER_NAME':"
echo ""
while IFS= read -r vm_json; do
    [ -z "$vm_json" ] || [ "$vm_json" = "null" ] && continue
    VM_UUID=$(echo "$vm_json" | jq -r '.metadata.uuid // empty')
    VM_NAME=$(echo "$vm_json" | jq -r '.spec.name // .status.name // "unknown"')
    [ -n "$VM_UUID" ] && echo "  - $VM_NAME (UUID: $VM_UUID)"
done <<< "$POWERED_OFF_VMS"
echo ""

read -p "Do you want to delete these $POWERED_OFF_COUNT VM(s) via v3 API (DELETE /api/nutanix/v3/vms/{uuid})? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo "Deleting VMs..."
DELETED_COUNT=0
FAILED_COUNT=0

while IFS= read -r vm_uuid; do
    [ -z "$vm_uuid" ] || [ "$vm_uuid" = "null" ] && continue
    VM_NAME=$(echo "$POWERED_OFF_VMS" | jq -r --arg u "$vm_uuid" 'select(.metadata.uuid == $u) | .spec.name // .status.name // "unknown"' | head -1)
    [ -z "$VM_NAME" ] && VM_NAME="$vm_uuid"

    echo "  Deleting VM: $VM_NAME ($vm_uuid)..."
    RESPONSE=$(api_call "DELETE" "/api/nutanix/v3/vms/${vm_uuid}" 2>/dev/null)

    # v3 Delete VM returns 202 Accepted; response may have metadata or be minimal
    if echo "$RESPONSE" | jq -e '.metadata.uuid' >/dev/null 2>&1; then
        echo "    ✓ Delete accepted (v3)"
        DELETED_COUNT=$((DELETED_COUNT + 1))
    elif ! echo "$RESPONSE" | jq -e '.message_list' >/dev/null 2>&1 && [ -n "$RESPONSE" ]; then
        echo "    ✓ Delete accepted (v3, 202)"
        DELETED_COUNT=$((DELETED_COUNT + 1))
    elif [ -z "$RESPONSE" ]; then
        # Empty response often means 202 with no body
        echo "    ✓ Delete accepted (v3)"
        DELETED_COUNT=$((DELETED_COUNT + 1))
    else
        ERR=$(echo "$RESPONSE" | jq -r '.message_list[0].message // .message // "unknown"' 2>/dev/null)
        echo "    ✗ Failed: $ERR"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
done <<< "$POWERED_OFF_VM_UUIDS"

echo ""
echo "=========================================="
echo "Summary:"
echo "  Delete accepted: $DELETED_COUNT"
echo "  Failed:          $FAILED_COUNT"
echo "=========================================="
echo ""
echo "Note: v3 VM delete is asynchronous (202). Check Prism Central tasks for completion."
echo "After VMs are deleted, you can run mass-delete-storage.sh to remove their volume groups."
