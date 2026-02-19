#!/bin/bash
set -uo pipefail

# Script to delete all volume groups (Kubernetes PVCs) associated with powered-off VMs in a specific Kubernetes cluster.
# Prism Central requires: (1) detach VG from VM, (2) delete VG, (3) delete VM — in that order.
#
# Recommended workflow:
#   1. ./mass-delete-storage.sh --cluster <name> --detach-only   # detach only; writes volumes.list.tmp
#   2. ./mass-delete-storage.sh --volumes volumes.list.tmp       # delete volume groups from file (or use --cluster to re-discover)
#   3. ./mass-delete-vms.sh --cluster <name>                      # delete VMs

# Source env.vars for API credentials (but NOT for CLUSTER_NAME)
# Note: CLUSTER_NAME may be in env.vars, but we'll ignore it and require --cluster flag
if [ -f env.vars ]; then
    source env.vars
else
    echo "ERROR: env.vars file not found. Create it and add your NUTANIX_ENDPOINT, NUTANIX_USER, and NUTANIX_PASSWORD." >&2
    exit 1
fi

# Parse command line arguments
# Use CLUSTER_NAME_ARG to avoid conflict with CLUSTER_NAME from env.vars
CLUSTER_NAME_ARG=""
VOLUMES_FILE=""
DETACH_ONLY=false
DEBUG_DETACH=false
while [ $# -gt 0 ]; do
    case "$1" in
        --cluster)
            if [ $# -lt 2 ]; then
                echo "ERROR: --cluster requires a value" >&2
                echo "Usage: $0 --cluster <cluster-name> [--detach-only] [--debug]" >&2
                echo "   or: $0 --volumes <file> [--debug]" >&2
                exit 1
            fi
            CLUSTER_NAME_ARG="$2"
            shift 2
            ;;
        --volumes)
            if [ $# -lt 2 ]; then
                echo "ERROR: --volumes requires a file path" >&2
                echo "Usage: $0 --volumes <file> [--debug]" >&2
                exit 1
            fi
            VOLUMES_FILE="$2"
            shift 2
            ;;
        --detach-only)
            DETACH_ONLY=true
            shift
            ;;
        --debug)
            DEBUG_DETACH=true
            shift
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 --cluster <cluster-name> [--detach-only] [--debug]" >&2
            echo "   or: $0 --volumes <file> [--debug]" >&2
            exit 1
            ;;
    esac
done

# Validate: need either --cluster or --volumes
if [ -n "$VOLUMES_FILE" ]; then
    if [ ! -f "$VOLUMES_FILE" ]; then
        echo "ERROR: Volumes file not found: $VOLUMES_FILE" >&2
        exit 1
    fi
    CLUSTER_NAME="${CLUSTER_NAME_ARG:-from file}"
elif [ -z "$CLUSTER_NAME_ARG" ]; then
    echo "ERROR: Either --cluster or --volumes is required" >&2
    echo "Usage: $0 --cluster <cluster-name> [--detach-only] [--debug]" >&2
    echo "   or: $0 --volumes <file> [--debug]" >&2
    exit 1
else
    CLUSTER_NAME="$CLUSTER_NAME_ARG"
fi

# Set defaults if not provided
NUTANIX_ENDPOINT="${NUTANIX_ENDPOINT:-}"
NUTANIX_USER="${NUTANIX_USER:-admin}"
NUTANIX_PASSWORD="${NUTANIX_PASSWORD:-}"

# API behavior: timeout (seconds), retries for delete (transient/RPC errors), delay between VG deletes (seconds)
CURL_TIMEOUT="${CURL_TIMEOUT:-90}"
DELETE_RETRIES="${DELETE_RETRIES:-3}"
DELETE_RETRY_DELAYS="2 5 10"
DELAY_BETWEEN_VGS="${DELAY_BETWEEN_VGS:-3}"
# Wait after detach before attempting delete (PC may need time to complete detach task)
DETACH_WAIT_SECONDS="${DETACH_WAIT_SECONDS:-30}"

# Validate required variables
if [ -z "$NUTANIX_ENDPOINT" ]; then
    echo "ERROR: NUTANIX_ENDPOINT is not set. Set it in env.vars or export it." >&2
    exit 1
fi

if [ -z "$NUTANIX_PASSWORD" ]; then
    echo "ERROR: NUTANIX_PASSWORD is not set. Set it in env.vars or export it." >&2
    exit 1
fi

# Parse endpoint URL - extract IP and port
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
if [ "$DETACH_ONLY" = true ]; then
    echo "Mode: DETACH ONLY (no VG deletion; run again without --detach-only to delete, then mass-delete-vms.sh for VMs)"
else
    echo "  (Delete: ${DELETE_RETRIES} retries on RPC/transient errors, ${DELAY_BETWEEN_VGS}s between VGs, ${DETACH_WAIT_SECONDS}s wait after detach, curl timeout ${CURL_TIMEOUT}s)"
fi
[ "$DEBUG_DETACH" = true ] && echo "Debug: detach API responses will be printed."
echo ""

# Print detach API response for debugging (when --debug is set)
debug_detach_response() {
    local label=$1
    local body=$2
    [ "$DEBUG_DETACH" != true ] && return
    echo "    [DEBUG] $label response:"
    if [ -z "$body" ]; then
        echo "      (empty body)"
    else
        local out
        out=$(echo "$body" | jq -c . 2>/dev/null || echo "$body")
        echo "${out:0:1200}"
        [ ${#out} -gt 1200 ] && echo "... (truncated)"
    fi
    echo "    [DEBUG] ---"
}

# Generate a UUID for request ID
generate_request_id() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    else
        # Fallback: generate a simple UUID-like string
        cat /dev/urandom 2>/dev/null | tr -dc 'a-f0-9' | fold -w 8 | head -n 1 | sed 's/^\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)$/\1-\2-\3-\4-\5/' || echo "fallback-$(date +%s)-$$"
    fi
}

# Function to make API calls to Prism Central
api_call() {
    local method=$1
    local endpoint=$2
    local data=${3:-}
    local request_id=${4:-}
    
    # Generate request ID if not provided (required for v4.1 DELETE and POST actions)
    if [ -z "$request_id" ]; then
        request_id=$(generate_request_id)
    fi
    
    if [ "$method" = "POST" ]; then
        if [ -n "$data" ]; then
            # POST with data (like detach action) - requires NTNX-Request-Id
            curl -k -s --max-time "$CURL_TIMEOUT" \
                -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
                -H "Content-Type: application/json" \
                -H "Accept: application/json" \
                -H "NTNX-Request-Id: ${request_id}" \
                -X POST \
                -d "$data" \
                "${PC_BASE_URL}${endpoint}"
        else
            # POST without data (like list API)
            curl -k -s --max-time "$CURL_TIMEOUT" \
                -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
                -H "Content-Type: application/json" \
                -H "Accept: application/json" \
                -X POST \
                "${PC_BASE_URL}${endpoint}"
        fi
    elif [ "$method" = "DELETE" ]; then
        # DELETE requires NTNX-Request-Id for v4.1 API
        curl -k -s --max-time "$CURL_TIMEOUT" \
            -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
            -H "Accept: application/json" \
            -H "NTNX-Request-Id: ${request_id}" \
            -X DELETE \
            "${PC_BASE_URL}${endpoint}"
    elif [ "$method" = "PUT" ]; then
        # PUT with body (e.g. VM update)
        curl -k -s --max-time "$CURL_TIMEOUT" \
            -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            -X PUT \
            -d "$data" \
            "${PC_BASE_URL}${endpoint}"
    elif [ "$method" = "GET" ]; then
        curl -k -s --max-time "$CURL_TIMEOUT" \
            -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
            -H "Accept: application/json" \
            -X GET \
            "${PC_BASE_URL}${endpoint}"
    fi
}

# Call Prism Element (cluster) API - same auth, different base URL (v2 detach is supported on PE, not PC)
cluster_call() {
    local base_url=$1
    local method=$2
    local endpoint=$3
    local data=${4:-}
    if [ "$method" = "POST" ] && [ -n "$data" ]; then
        curl -k -s --max-time "$CURL_TIMEOUT" \
            -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            -X POST \
            -d "$data" \
            "${base_url}${endpoint}"
    else
        curl -k -s --max-time "$CURL_TIMEOUT" \
            -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
            -H "Accept: application/json" \
            -X GET \
            "${base_url}${endpoint}"
    fi
}

# Step 1 & 2: Either discover VGs from cluster VMs, or load from --volumes file
if [ -n "$VOLUMES_FILE" ]; then
    echo "Loading volume group list from: $VOLUMES_FILE"
    VGS_TO_DELETE=""
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if echo "$line" | jq -e '.uuid and .name' >/dev/null 2>&1; then
            if [ -z "$VGS_TO_DELETE" ]; then
                VGS_TO_DELETE="$line"
            else
                VGS_TO_DELETE="$VGS_TO_DELETE"$'\n'"$line"
            fi
        fi
    done < "$VOLUMES_FILE"
    VG_COUNT=$(echo "$VGS_TO_DELETE" | jq -s 'length' 2>/dev/null || echo "0")
    if [ "$VG_COUNT" -eq 0 ]; then
        echo "ERROR: No valid volume group entries (uuid, name) found in $VOLUMES_FILE" >&2
        exit 1
    fi
    echo "  Loaded $VG_COUNT volume group(s)"
    echo ""
    echo "Fetching current volume group state from Prism Central (for attachment check)..."
    VG_LIST_RESPONSE=$(api_call "POST" "/api/nutanix/v3/volume_groups/list" '{"kind":"volume_group","length":500}')
    echo ""
else
# Step 1: Get all powered-off VMs in the specified cluster
echo "Step 1: Finding powered-off VMs in cluster '$CLUSTER_NAME'..."
VM_LIST_RESPONSE=$(api_call "POST" "/api/nutanix/v3/vms/list" '{"kind":"vm","length":500}')

# Filter for powered-off VMs with the specified cluster name
# Check multiple possible locations for cluster name
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

# Extract UUIDs from the filtered VMs (handle both single object and stream)
POWERED_OFF_VM_UUIDS=$(echo "$POWERED_OFF_VMS" | jq -r 'if type == "array" then .[] else . end | .metadata.uuid // empty' | grep -v '^$' | grep -v '^null$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

POWERED_OFF_COUNT=$(echo "$POWERED_OFF_VM_UUIDS" | wc -l | tr -d ' ')

if [ "$POWERED_OFF_COUNT" -eq 0 ]; then
    echo "No powered-off VMs found in cluster '$CLUSTER_NAME'."
    exit 0
fi

echo "Found $POWERED_OFF_COUNT powered-off VM(s) in cluster '$CLUSTER_NAME'"
echo ""

# Step 2: Get all volume groups and find PVCs attached to powered-off VMs using direct match
echo "Step 2: Finding volume groups (PVCs) attached to powered-off VMs..."
echo "  Note: This will find PVCs attached to powered-off VMs in cluster '$CLUSTER_NAME'"
echo "  Using direct match from VM disk_list (more reliable than reverse lookup)"
echo ""
VG_LIST_RESPONSE=$(api_call "POST" "/api/nutanix/v3/volume_groups/list" '{"kind":"volume_group","length":500}')

# Use direct match approach: Extract volume group UUIDs from powered-off VMs' disk_list
# and match them to PVCs in the LIST response
VGS_TO_DELETE=""
MATCHED=0

echo "  Extracting volume group references from powered-off VMs..."
while IFS= read -r vm_json; do
    if [ -z "$vm_json" ] || [ "$vm_json" = "null" ] || [ "$vm_json" = "" ]; then
        continue
    fi
    
    # Validate JSON
    if ! echo "$vm_json" | jq -e '.' >/dev/null 2>&1; then
        continue
    fi
    
    VM_UUID=$(echo "$vm_json" | jq -r '.metadata.uuid // empty' 2>/dev/null)
    VM_NAME=$(echo "$vm_json" | jq -r '.spec.name // .status.name // "unknown"' 2>/dev/null)
    
    if [ -z "$VM_UUID" ] || [ "$VM_UUID" = "null" ]; then
        continue
    fi
    
    # Extract volume group UUIDs from VM disk_list
    VM_VG_UUIDS=$(echo "$vm_json" | jq -r '.spec.resources.disk_list[]? // .status.resources.disk_list[]? // empty | select(.device_properties.device_type == "VOLUME_GROUP") | .volume_group_reference.uuid // empty' 2>/dev/null | grep -v '^$' | grep -v '^null$')
        
    # For each volume group UUID, check if it's a PVC and store for deletion
    if [ -n "$VM_VG_UUIDS" ]; then
        while IFS= read -r vg_uuid; do
            if [ -z "$vg_uuid" ] || [ "$vg_uuid" = "null" ]; then
                    continue
                fi
            
            # Check if this volume group UUID is a PVC (name starts with "pvc-") in the LIST response
            PVC_INFO=$(echo "$VG_LIST_RESPONSE" | jq -c --arg uuid "$vg_uuid" '.entities[]? | select(.metadata.uuid == $uuid and ((.spec.name // .status.name // "") | startswith("pvc-"))) | {uuid: .metadata.uuid, name: (.spec.name // .status.name)}' 2>/dev/null)
            
            if [ -n "$PVC_INFO" ] && [ "$PVC_INFO" != "null" ]; then
                PVC_UUID=$(echo "$PVC_INFO" | jq -r '.uuid // empty')
                PVC_NAME=$(echo "$PVC_INFO" | jq -r '.name // empty')
                
                if [ -n "$PVC_UUID" ] && [ -n "$PVC_NAME" ]; then
                    # Check if we've already added this PVC (avoid duplicates)
                    if ! echo "$VGS_TO_DELETE" | jq -s -e --arg uuid "$PVC_UUID" '.[] | select(.uuid == $uuid)' >/dev/null 2>&1; then
            MATCHED=$((MATCHED + 1))
                        MATCH_ENTRY=$(jq -n --arg uuid "$PVC_UUID" --arg name "$PVC_NAME" --arg vm "$VM_UUID" --arg vm_name "$VM_NAME" '{uuid: $uuid, name: $name, attached_vm: $vm, attached_vm_name: $vm_name}')
            if [ -z "$VGS_TO_DELETE" ]; then
                VGS_TO_DELETE="$MATCH_ENTRY"
            else
                VGS_TO_DELETE="$VGS_TO_DELETE"$'\n'"$MATCH_ENTRY"
            fi
        fi
    fi
            fi
        done <<< "$VM_VG_UUIDS"
    fi
done <<< "$POWERED_OFF_VMS"

VG_COUNT=$(echo "$VGS_TO_DELETE" | jq -s 'length' || echo "0")
echo "  Found $VG_COUNT PVC(s) attached to powered-off VMs"
echo ""

if [ "$VG_COUNT" -eq 0 ]; then
    echo "No volume groups found attached to powered-off VMs in cluster '$CLUSTER_NAME'."
    echo ""
    echo "  Possible reasons:"
    echo "    1. PVCs are attached to VMs in a different cluster (not '$CLUSTER_NAME')"
    echo "    2. PVCs are attached to VMs that are powered ON"
    echo "    3. No PVCs exist for this cluster"
    echo ""
    echo "  Tip: Check the debug output above to see which clusters the attached VMs belong to."
    echo "  You may need to run this script with a different --cluster value (e.g., 'konnkp', 'kon-hoihoi', 'mgmt-cluster')."
    exit 0
fi

fi
# end of "discover from cluster" branch

echo "Found $VG_COUNT volume group(s) to process:"
if echo "$VGS_TO_DELETE" | jq -s -e '.[0].attached_vm_name' >/dev/null 2>&1; then
    echo "$VGS_TO_DELETE" | jq -s -r '.[] | "  - \(.name) (UUID: \(.uuid), VM: \(.attached_vm_name // .attached_vm))"'
else
echo "$VGS_TO_DELETE" | jq -s -r '.[] | "  - \(.name) (UUID: \(.uuid), VM: \(.attached_vm))"'
fi
echo ""

# Step 3: Confirm before deletion or detach-only
if [ "$DETACH_ONLY" = true ]; then
    read -p "Do you want to DETACH (only) these $VG_COUNT volume group(s) from their VMs? (yes/no): " CONFIRM
else
    read -p "Do you want to delete these $VG_COUNT volume group(s)? (yes/no): " CONFIRM
fi
if [ "$CONFIRM" != "yes" ]; then
    echo "Cancelled."
    exit 0
fi

# Step 4: Detach and (unless --detach-only) delete volume groups
echo ""
if [ "$DETACH_ONLY" = true ]; then
    echo "Step 4: Detaching VMs from volume groups (no deletion)..."
    # Write volume list for later delete run (--volumes volumes.list.tmp)
    VOLUMES_LIST_TMP="volumes.list.tmp"
    echo "$VGS_TO_DELETE" | jq -c -s '.[] | {uuid, name, attached_vm, attached_vm_name}' 2>/dev/null > "$VOLUMES_LIST_TMP"
    echo "  Wrote $VG_COUNT volume group(s) to $VOLUMES_LIST_TMP"
    echo ""
else
    echo "Step 4: Detaching VMs and deleting volume groups..."
fi
DELETED_COUNT=0
DETACHED_COUNT=0
FAILED_COUNT=0

# Process each volume group
while IFS= read -r vg_info; do
    if [ -z "$vg_info" ]; then
        continue
    fi
    
    vg_uuid=$(echo "$vg_info" | jq -r '.uuid')
    vg_name=$(echo "$vg_info" | jq -r '.name')
    
    if [ -z "$vg_uuid" ] || [ "$vg_uuid" = "null" ]; then
        echo "  ✗ Skipping invalid volume group entry"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    fi
    
    echo "Processing: $vg_name (UUID: $vg_uuid)..."
    
    # Step 4a: Get attachment info from LIST response (already have it, no need for individual GET)
    PVC_FROM_LIST=$(echo "$VG_LIST_RESPONSE" | jq -c --arg uuid "$vg_uuid" '.entities[]? | select(.metadata.uuid == $uuid)')
    
    # Extract attachments from LIST response (v3 format)
    ATTACHED_VM_UUIDS=$(echo "$PVC_FROM_LIST" | jq -r '.status.resources.attachment_list[]?.vm_reference.uuid // empty' 2>/dev/null | grep -v '^$' | grep -v '^null$')
    
    # Step 4b: Detach all VMs from the volume group (if any attachments found)
    if [ -n "$ATTACHED_VM_UUIDS" ]; then
        ATTACHMENT_COUNT=$(echo "$ATTACHED_VM_UUIDS" | wc -l | tr -d ' ')
        echo "  Found $ATTACHMENT_COUNT VM attachment(s) in LIST response"
        echo "  Attempting detach (v3, volumes v4.1 detach-vm, Prism Element v2.0, VM-update fallback)..."
        
        DETACH_SUCCESS=false
        while IFS= read -r vm_uuid; do
            if [ -z "$vm_uuid" ] || [ "$vm_uuid" = "null" ]; then
                continue
            fi
            # Fetch VM once for cluster lookup (Prism Element detach) and VM-update fallback
            VM_GET=$(api_call "GET" "/api/nutanix/v3/vms/${vm_uuid}" 2>/dev/null)
            DETACH_RESPONSE_PE=""
            
            # 1) Try v3 API detach (legacy; often "URL not found" on newer PC)
            DETACH_PAYLOAD_V3=$(jq -n \
                --arg vm_uuid "$vm_uuid" \
                '{"vm_reference": {"kind": "vm", "uuid": $vm_uuid}}')
            DETACH_RESPONSE_V3=$(api_call "POST" "/api/nutanix/v3/volume_groups/${vg_uuid}/detach" "$DETACH_PAYLOAD_V3" 2>/dev/null)
            debug_detach_response "v3 volume_groups/detach" "$DETACH_RESPONSE_V3"
            if echo "$DETACH_RESPONSE_V3" | jq -e '.status.state == "COMPLETE"' >/dev/null 2>&1 || echo "$DETACH_RESPONSE_V3" | jq -e '.status.state == "SUCCEEDED"' >/dev/null 2>&1; then
                echo "    ✓ Detached VM: $vm_uuid (v3 API)"
                DETACH_SUCCESS=true
                continue
            fi
            
            # 2) Try v3 with vm_reference_list (array)
            DETACH_PAYLOAD_V3_LIST=$(jq -n \
                --arg vm_uuid "$vm_uuid" \
                '{"vm_reference_list": [{"kind": "vm", "uuid": $vm_uuid}]}')
            DETACH_RESPONSE_V3B=$(api_call "POST" "/api/nutanix/v3/volume_groups/${vg_uuid}/detach" "$DETACH_PAYLOAD_V3_LIST" 2>/dev/null)
            debug_detach_response "v3 volume_groups/detach (list body)" "$DETACH_RESPONSE_V3B"
            if echo "$DETACH_RESPONSE_V3B" | jq -e '.status.state == "COMPLETE"' >/dev/null 2>&1 || echo "$DETACH_RESPONSE_V3B" | jq -e '.status.state == "SUCCEEDED"' >/dev/null 2>&1; then
                echo "    ✓ Detached VM: $vm_uuid (v3 API, list body)"
                DETACH_SUCCESS=true
                continue
            fi
            
            # 3) Volumes v4.1 detach-vm: POST .../volume-groups/{id}/$actions/detach-vm with body extId (VM uuid) + $objectType (matches Prism UI)
            DETACH_PAYLOAD_V4=$(jq -n \
                --arg vm_uuid "$vm_uuid" \
                '{extId: $vm_uuid, "$objectType": "volumes.v4.config.VmAttachment", "$reserved": {"$fv": "v4.r1"}, "$unknownFields": {}}')
            DETACH_RESPONSE_V4=$(api_call "POST" "/api/volumes/v4.1/config/volume-groups/${vg_uuid}/\$actions/detach-vm" "$DETACH_PAYLOAD_V4" 2>/dev/null)
            debug_detach_response "volumes v4.1 detach-vm" "$DETACH_RESPONSE_V4"
            if echo "$DETACH_RESPONSE_V4" | jq -e '.error or (.status == 404 or .status == 400)' >/dev/null 2>&1; then
                : # v4.1 returned error, fall through
            elif echo "$DETACH_RESPONSE_V4" | jq -e '.data.extId or .data' >/dev/null 2>&1; then
                echo "    ✓ Detached VM: $vm_uuid (volumes v4.1 detach-vm)"
                DETACH_SUCCESS=true
                continue
            elif ! echo "$DETACH_RESPONSE_V4" | jq -e '.message_list or .error' >/dev/null 2>&1 && [ -n "$DETACH_RESPONSE_V4" ]; then
                echo "    ✓ Detached VM: $vm_uuid (volumes v4.1 detach-vm, accepted)"
                DETACH_SUCCESS=true
                continue
            elif [ -z "$DETACH_RESPONSE_V4" ]; then
                echo "    ✓ Detached VM: $vm_uuid (volumes v4.1 detach-vm, accepted)"
                DETACH_SUCCESS=true
                continue
            fi
            
            # 4) Prism Element (cluster) v2.0 detach - may work on the cluster when PC doesn't support it
            CLUSTER_UUID=$(echo "$VM_GET" | jq -r '.spec.cluster_reference.uuid // .metadata.cluster_reference.uuid // empty' 2>/dev/null)
            if [ -n "$CLUSTER_UUID" ] && [ "$CLUSTER_UUID" != "null" ]; then
                CLUSTER_GET=$(api_call "GET" "/api/nutanix/v3/clusters/${CLUSTER_UUID}" 2>/dev/null)
                CLUSTER_IP=$(echo "$CLUSTER_GET" | jq -r '
                    .status.resources.network.external_ip //
                    .spec.resources.network.external_ip //
                    .status.resources.config.external_data_services_config.management_server_list[0].value //
                    .spec.resources.config.management_server_list[0].value //
                    .spec.resources.network.ip_list[0] //
                    .status.resources.network.ip_list[0] //
                    empty
                ' 2>/dev/null)
                if [ -n "$CLUSTER_IP" ] && [ "$CLUSTER_IP" != "null" ]; then
                    CLUSTER_BASE="https://${CLUSTER_IP}:9440"
                    DETACH_PAYLOAD_V2=$(jq -n \
                        --arg vm_uuid "$vm_uuid" \
                        '{operation: "DETACH", vm_uuid: $vm_uuid, index: 0, logical_timestamp: 0, vm_logical_timestamp: 0}')
                    DETACH_RESPONSE_PE=$(cluster_call "$CLUSTER_BASE" "POST" "/PrismGateway/services/rest/v2.0/volume_groups/${vg_uuid}/detach" "$DETACH_PAYLOAD_V2" 2>/dev/null)
                    debug_detach_response "Prism Element (cluster) v2.0 volume_groups/detach" "$DETACH_RESPONSE_PE"
                    if echo "$DETACH_RESPONSE_PE" | jq -e '.message or .error_code' >/dev/null 2>&1; then
                        : # PE returned error, fall through
                    elif [ -z "$DETACH_RESPONSE_PE" ] || echo "$DETACH_RESPONSE_PE" | jq -e '.value or .task_uuid' >/dev/null 2>&1; then
                        echo "    ✓ Detached VM: $vm_uuid (Prism Element v2.0 volume_groups/detach)"
                        DETACH_SUCCESS=true
                        continue
                    fi
                fi
            fi
            
            # 5) Fallback: remove the volume group disk from the VM's disk_list via VM update (PC may accept then fail task: "Modifying volume group attachments is disallowed")
            echo "    Trying fallback: remove VG disk from VM spec (VM must be OFF)..."
            if echo "$VM_GET" | jq -e '.spec' >/dev/null 2>&1; then
                POWER_STATE=$(echo "$VM_GET" | jq -r '.status.resources.power_state // .spec.resources.power_state // "UNKNOWN"' 2>/dev/null)
                if [ "$POWER_STATE" != "OFF" ]; then
                    echo "    ⚠ Fallback skipped: VM $vm_uuid is $POWER_STATE (must be OFF to modify disk_list)"
                else
                    # Build new disk_list without the disk that references this volume group
                    NEW_DISK_LIST=$(echo "$VM_GET" | jq -c --arg vg_uuid "$vg_uuid" '.spec.resources.disk_list | map(select((.volume_group_reference.uuid // "") != $vg_uuid))' 2>/dev/null)
                    if [ -n "$NEW_DISK_LIST" ] && [ "$NEW_DISK_LIST" != "null" ]; then
                        VM_SPEC=$(echo "$VM_GET" | jq -c --argjson disks "$NEW_DISK_LIST" '.spec | .resources.disk_list = $disks' 2>/dev/null)
                        VM_METADATA=$(echo "$VM_GET" | jq -c '.metadata' 2>/dev/null)
                        if [ -n "$VM_SPEC" ] && [ -n "$VM_METADATA" ] && [ "$VM_METADATA" != "null" ]; then
                            # Nutanix v3 VM update requires metadata + spec (422 if metadata missing)
                            VM_UPDATE_BODY=$(jq -n --argjson metadata "$VM_METADATA" --argjson spec "$VM_SPEC" '{metadata: $metadata, spec: $spec, api_version: "3.1"}')
                            VM_UPDATE_RESPONSE=$(api_call "PUT" "/api/nutanix/v3/vms/${vm_uuid}" "$VM_UPDATE_BODY" 2>/dev/null)
                            debug_detach_response "VM update (remove disk)" "$VM_UPDATE_RESPONSE"
                            if echo "$VM_UPDATE_RESPONSE" | jq -e '.metadata.uuid' >/dev/null 2>&1; then
                                echo "    ✓ Removed VG disk from VM $vm_uuid (VM update fallback)"
                                DETACH_SUCCESS=true
                                continue
                            fi
                            ERR_UPDATE=$(echo "$VM_UPDATE_RESPONSE" | jq -r '.message_list[0].message // .message // empty' 2>/dev/null)
                            if [ -z "$ERR_UPDATE" ] && [ -n "$VM_UPDATE_RESPONSE" ]; then
                                ERR_UPDATE=$(echo "$VM_UPDATE_RESPONSE" | jq -c . 2>/dev/null | head -c 200)
                            fi
                            echo "    ⚠ VM update failed: ${ERR_UPDATE:-empty response}"
                        fi
                    fi
                fi
            fi
            
            # Surface errors (prefer first attempted API that returned an error)
            ERR_V3=$(echo "$DETACH_RESPONSE_V3" | jq -r '.message_list[0].message // .message // empty' 2>/dev/null)
            [ -z "$ERR_V3" ] && ERR_V3=$(echo "$DETACH_RESPONSE_V3B" | jq -r '.message_list[0].message // .message // empty' 2>/dev/null)
            ERR_V4=$(echo "$DETACH_RESPONSE_V4" | jq -r '.message // empty' 2>/dev/null)
            ERR_PE=$(echo "$DETACH_RESPONSE_PE" | jq -r '.message // .error // empty' 2>/dev/null)
            if [ -n "$ERR_V3" ]; then
                echo "    ⚠ Detach VM $vm_uuid (v3): $ERR_V3"
            elif [ -n "$ERR_V4" ]; then
                echo "    ⚠ Detach VM $vm_uuid (volumes v4.1): $ERR_V4"
            elif [ -n "$ERR_PE" ]; then
                echo "    ⚠ Detach VM $vm_uuid (Prism Element v2.0): $ERR_PE"
            else
                echo "    ⚠ Detach VM $vm_uuid: no detach method succeeded"
            fi
        done <<< "$ATTACHED_VM_UUIDS"
        
        if [ "$DETACH_SUCCESS" = true ]; then
            [ "$DETACH_ONLY" = true ] && DETACHED_COUNT=$((DETACHED_COUNT + 1))
            if [ "$DETACH_ONLY" != true ]; then
                echo "  Waiting ${DETACH_WAIT_SECONDS} seconds for detach to complete..."
                sleep "$DETACH_WAIT_SECONDS"
            fi
        fi
    else
        echo "  No attachments found in LIST response (already detached), skipping detach step"
        [ "$DETACH_ONLY" = true ] && DETACHED_COUNT=$((DETACHED_COUNT + 1))
    fi

    if [ "$DETACH_ONLY" = true ]; then
        echo "  (Skipping delete in --detach-only mode)"
        if [ -n "$ATTACHED_VM_UUIDS" ] && [ "$DETACH_SUCCESS" != true ]; then
            FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
        if [ "$DELAY_BETWEEN_VGS" -gt 0 ]; then
            sleep "$DELAY_BETWEEN_VGS"
        fi
        echo ""
        continue
    fi
    
    # Step 4c: Delete the volume group - try v4.1 first (recommended), then v3, with retries for RPC/transient failures
    # Note: v3 often returns "Failed to send RPC request" for volume group deletes; v4.1 is the recommended API.
    echo "  Deleting volume group..."

    DELETE_SUCCEEDED=false
    RETRY_NUM=0
    for RETRY_DELAY in $DELETE_RETRY_DELAYS; do
        [ "$RETRY_NUM" -gt 0 ] && echo "  Retry $RETRY_NUM/$DELETE_RETRIES in ${RETRY_DELAY}s (RPC/transient errors may succeed on retry)..."
        [ "$RETRY_NUM" -gt 0 ] && sleep "$RETRY_DELAY"

        # Try v4.1 API first (recommended for volume operations; v3 is legacy and often fails with RPC errors)
        DELETE_RESPONSE_V4=$(api_call "DELETE" "/api/volumes/v4.1/config/volume-groups/${vg_uuid}" 2>/dev/null)

        if echo "$DELETE_RESPONSE_V4" | jq -e '.data.extId' >/dev/null 2>&1; then
            DELETE_TASK_ID=$(echo "$DELETE_RESPONSE_V4" | jq -r '.data.extId')
            echo "  ✓ Delete request accepted via v4.1 API (task ID: $DELETE_TASK_ID)"
            DELETED_COUNT=$((DELETED_COUNT + 1))
            DELETE_SUCCEEDED=true
            break
        fi

        # v4.1 not available or failed - try v3 as fallback
        DELETE_RESPONSE_V3=$(api_call "DELETE" "/api/nutanix/v3/volume_groups/${vg_uuid}" 2>/dev/null)

        if echo "$DELETE_RESPONSE_V3" | jq -e '.status.state == "COMPLETE"' >/dev/null 2>&1 || echo "$DELETE_RESPONSE_V3" | jq -e '.status.state == "SUCCEEDED"' >/dev/null 2>&1; then
            DELETE_TASK_ID=$(echo "$DELETE_RESPONSE_V3" | jq -r '.status.execution_context.task_uuid // .metadata.uuid // "unknown"' 2>/dev/null)
            echo "  ✓ Delete request accepted via v3 API (task ID: $DELETE_TASK_ID)"
            DELETED_COUNT=$((DELETED_COUNT + 1))
            DELETE_SUCCEEDED=true
            break
        fi

        # Check for retryable error from either API (RPC/network/transient)
        ERROR_MSG=$(echo "$DELETE_RESPONSE_V4" | jq -r '.data.error[0].message // .message // empty' 2>/dev/null)
        [ -z "$ERROR_MSG" ] && ERROR_MSG=$(echo "$DELETE_RESPONSE_V3" | jq -r '.message_list[0].message // .message // empty' 2>/dev/null)

        if [ -n "$ERROR_MSG" ]; then
            if echo "$ERROR_MSG" | grep -qi "RPC request\|timeout\|connection\|temporarily\|unavailable"; then
                RETRY_NUM=$((RETRY_NUM + 1))
                if [ "$RETRY_NUM" -lt "$DELETE_RETRIES" ]; then
                    echo "  ⚠ API returned retryable error: $ERROR_MSG"
                    continue
                fi
            fi
            echo "  ✗ Failed to delete: $ERROR_MSG"
            FAILED_COUNT=$((FAILED_COUNT + 1))
            break
        fi

        # Unexpected response from both
        echo "  ✗ Failed to delete (unexpected response from v4.1 and v3)"
        echo "  v4.1:" && echo "$DELETE_RESPONSE_V4" | jq . 2>/dev/null | head -5
        echo "  v3:"   && echo "$DELETE_RESPONSE_V3" | jq . 2>/dev/null | head -5
        FAILED_COUNT=$((FAILED_COUNT + 1))
        break
    done

    # Throttle: delay between volume groups to avoid overwhelming Prism Central / cluster RPC
    if [ "$DELAY_BETWEEN_VGS" -gt 0 ]; then
        sleep "$DELAY_BETWEEN_VGS"
    fi
    echo ""
done < <(echo "$VGS_TO_DELETE" | jq -c -s '.[]')

echo "=========================================="
if [ "$DETACH_ONLY" = true ]; then
    echo "Detach-only Summary:"
    echo "  Detached (or had no attachments): $DETACHED_COUNT"
    echo "  Failed: $FAILED_COUNT"
    echo "=========================================="
    echo ""
    echo "Next steps:"
    echo "  1. In Prism Central, confirm volume groups show no VM attachments (or wait for detach tasks to complete)."
    echo "  2. Delete the volume groups using the written list:"
    echo "       $0 --volumes volumes.list.tmp"
    echo "  3. Then delete the VMs (if same cluster):"
    echo "       ./mass-delete-vms.sh --cluster $CLUSTER_NAME"
else
    echo "Deletion Summary:"
    echo "  Successfully deleted: $DELETED_COUNT"
    echo "  Failed: $FAILED_COUNT"
    echo "=========================================="
    echo ""
    if [ "$CLUSTER_NAME" != "from file" ]; then
        echo "To delete the VMs (after VGs are gone), run: ./mass-delete-vms.sh --cluster $CLUSTER_NAME"
    fi
fi
