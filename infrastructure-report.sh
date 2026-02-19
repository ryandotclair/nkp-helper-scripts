#!/bin/bash
set -uo pipefail

# Script to lookup and display all VMs with Kubernetes cluster names and their associated PVCs
# Output format:
# Cluster Name
#   |_VM Name
#      |_PVC Name

# Parse command line arguments
DEBUG=false
for arg in "$@"; do
    case $arg in
        --debug)
            DEBUG=true
            shift
            ;;
        *)
            # Unknown option
            ;;
    esac
done

if [ -f env.vars ]; then
    source env.vars
else
    echo "ERROR: env.vars file not found. Create it and add your NUTANIX_ENDPOINT, NUTANIX_USER, and NUTANIX_PASSWORD." >&2
    exit 1
fi

# Set defaults if not provided
NUTANIX_ENDPOINT="${NUTANIX_ENDPOINT:-}"
NUTANIX_USER="${NUTANIX_USER:-admin}"
NUTANIX_PASSWORD="${NUTANIX_PASSWORD:-}"

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
echo ""

# API call function
api_call() {
    local method=$1
    local endpoint=$2
    local data=${3:-}
    local full_url="${PC_BASE_URL}${endpoint}"
    local http_code
    local response_body
    local temp_response
    
    # Use temp file to capture response body (HTTP status code goes to stdout)
    temp_response=$(mktemp)
    
    if [ "$method" = "POST" ]; then
        if [ -n "$data" ]; then
            http_code=$(curl -k -s -w "%{http_code}" -o "$temp_response" \
                -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
                -H "Content-Type: application/json" \
                -H "Accept: application/json" \
                -X POST \
                -d "$data" \
                "${full_url}")
        else
            http_code=$(curl -k -s -w "%{http_code}" -o "$temp_response" \
                -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
                -H "Content-Type: application/json" \
                -H "Accept: application/json" \
                -X POST \
                "${full_url}")
        fi
    elif [ "$method" = "GET" ]; then
        http_code=$(curl -k -s -w "%{http_code}" -o "$temp_response" \
            -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
            -H "Accept: application/json" \
            -X GET \
            "${full_url}")
    fi
    
    response_body=$(cat "$temp_response")
    rm -f "$temp_response"
    
    # Print debug information if enabled
    if [ "$DEBUG" = true ]; then
        echo "DEBUG: API Call" >&2
        echo "  Method: $method" >&2
        echo "  URL: $full_url" >&2
        if [ -n "$data" ]; then
            echo "  Request Data: $data" >&2
        fi
        echo "  HTTP Status Code: $http_code" >&2
        echo "  Response Body:" >&2
        # Pretty print JSON if possible, otherwise print raw
        if echo "$response_body" | jq -e '.' >/dev/null 2>&1; then
            echo "$response_body" | jq '.' >&2
        else
            echo "$response_body" >&2
        fi
        echo "" >&2
    fi
    
    # Return the response body
    echo "$response_body"
}

# Step 1: Get all VMs with Kubernetes cluster names
echo "Step 1: Fetching VMs with Kubernetes cluster names..."
VM_LIST_RESPONSE=$(api_call "POST" "/api/nutanix/v3/vms/list" '{"kind":"vm","length":500}')

# Validate the response is valid JSON
if ! echo "$VM_LIST_RESPONSE" | jq -e '.' >/dev/null 2>&1; then
    echo "ERROR: Invalid JSON response from VM list API" >&2
    echo "Response: $VM_LIST_RESPONSE" >&2
    exit 1
fi

# Check if we got any VMs at all
TOTAL_MATCHES=$(echo "$VM_LIST_RESPONSE" | jq -r '.metadata.total_matches // 0' 2>/dev/null || echo "0")
ENTITIES_COUNT=$(echo "$VM_LIST_RESPONSE" | jq -r '.entities | length // 0' 2>/dev/null || echo "0")
if [ "$DEBUG" = true ]; then
    echo "DEBUG: VM List Response Analysis:" >&2
    echo "  Total matches (metadata.total_matches): $TOTAL_MATCHES" >&2
    echo "  Entities returned (entities array length): $ENTITIES_COUNT" >&2
    if [ "$TOTAL_MATCHES" -gt 500 ]; then
        echo "  WARNING: More than 500 VMs exist. Only first 500 are returned (pagination needed)." >&2
    fi
    echo "  Checking first VM structure (if any):" >&2
    echo "$VM_LIST_RESPONSE" | jq '.entities[0] | {name: .spec.name, metadata_categories: .metadata.categories}' >&2 2>/dev/null || echo "  (no VMs or invalid structure)" >&2
fi

# Filter for VMs that have a Kubernetes cluster name
K8S_VMS=$(echo "$VM_LIST_RESPONSE" | jq -c '
    .entities[]? | 
    select((.metadata.categories.KubernetesClusterName // "") != "")
')

if [ -z "$K8S_VMS" ]; then
    echo "No VMs with Kubernetes cluster names found."
    if [ "$DEBUG" = true ]; then
        echo "" >&2
        echo "DEBUG: Diagnostic information:" >&2
        echo "  Total matches: $TOTAL_MATCHES" >&2
        echo "  Entities in response: $ENTITIES_COUNT" >&2
        if [ "$ENTITIES_COUNT" != "0" ] && [ "$ENTITIES_COUNT" != "" ] && [ "$ENTITIES_COUNT" != "null" ]; then
            echo "  Sample VM names (first 5):" >&2
            echo "$VM_LIST_RESPONSE" | jq -r '.entities[0:5][]? | .spec.name // .status.name // "unknown"' 2>/dev/null | sed 's/^/    - /' >&2
            echo "  Checking for category fields in first VM:" >&2
            echo "$VM_LIST_RESPONSE" | jq '.entities[0] | {
                has_metadata_categories: (.metadata.categories != null),
                metadata_categories_keys: (.metadata.categories | keys),
                KubernetesClusterName: .metadata.categories.KubernetesClusterName
            }' >&2 2>/dev/null
        fi
    fi
    exit 0
fi

# Step 2: Get all PVCs and build VM to PVC mapping using direct match approach
echo "Step 2: Fetching all PVCs and building VM to PVC mapping..."
VG_LIST_RESPONSE=$(api_call "POST" "/api/nutanix/v3/volume_groups/list" '{"kind":"volume_group","length":500}')

# Build a mapping of VM UUID to PVC names using direct match from VM disk_list
# This is more reliable than reverse lookup (querying each PVC for attachments)
TEMP_PVC_MAP=$(mktemp)
TOTAL_PVCS=0

# For each VM, extract volume group UUIDs from disk_list and match to PVCs
echo "  Processing VMs to extract volume group references..."
VM_COUNT=0
while IFS= read -r vm_json; do
    if [ -z "$vm_json" ] || [ "$vm_json" = "null" ] || [ "$vm_json" = "" ]; then
        continue
    fi
    
    # Validate JSON
    if ! echo "$vm_json" | jq -e '.' >/dev/null 2>&1; then
        continue
    fi
    
    VM_COUNT=$((VM_COUNT + 1))
    VM_UUID=$(echo "$vm_json" | jq -r '.metadata.uuid // empty' 2>/dev/null)
    
    if [ -z "$VM_UUID" ] || [ "$VM_UUID" = "null" ]; then
        continue
    fi
    
    # Extract volume group UUIDs from VM disk_list
    VM_VG_UUIDS=$(echo "$vm_json" | jq -r '.spec.resources.disk_list[]? // .status.resources.disk_list[]? // empty | select(.device_properties.device_type == "VOLUME_GROUP") | .volume_group_reference.uuid // empty' 2>/dev/null | grep -v '^$' | grep -v '^null$')
    
    # For each volume group UUID, check if it's a PVC and store the mapping
    if [ -n "$VM_VG_UUIDS" ]; then
        while IFS= read -r vg_uuid; do
            if [ -z "$vg_uuid" ] || [ "$vg_uuid" = "null" ]; then
                continue
            fi
            
            # Check if this volume group UUID is a PVC (name starts with "pvc-")
            PVC_NAME=$(echo "$VG_LIST_RESPONSE" | jq -r --arg uuid "$vg_uuid" '.entities[]? | select(.metadata.uuid == $uuid and ((.spec.name // .status.name // "") | startswith("pvc-"))) | .spec.name // .status.name // ""' 2>/dev/null)
            
            if [ -n "$PVC_NAME" ] && [ "$PVC_NAME" != "null" ] && [ "$PVC_NAME" != "" ]; then
                echo "$VM_UUID|$PVC_NAME" >> "$TEMP_PVC_MAP"
            TOTAL_PVCS=$((TOTAL_PVCS + 1))
            fi
        done <<< "$VM_VG_UUIDS"
    fi
done <<< "$K8S_VMS"

echo "  Processed $VM_COUNT VM(s), found $TOTAL_PVCS PVC attachment(s)"
echo ""

# Group VMs by cluster and classify as controller/worker nodes
# Sort VMs by cluster name, then by VM name
# Convert stream to array, sort, then output as stream again
SORTED_VMS=$(echo "$K8S_VMS" | jq -s -c 'if length > 0 then sort_by(
    (.metadata.categories.KubernetesClusterName // "zzz-unknown"),
    (.spec.name // .status.name // "zzz-unknown")
) | .[] else empty end' 2>/dev/null)

if [ -z "$SORTED_VMS" ]; then
    echo "No VMs found after sorting."
    exit 0
fi

# Create temporary files for organizing VMs by cluster and node type
TEMP_CLUSTER_CONTROLLERS=$(mktemp)
TEMP_CLUSTER_WORKERS=$(mktemp)
TEMP_CLUSTER_LIST=$(mktemp)
# Update trap to include all temp files
trap "rm -f $TEMP_PVC_MAP $TEMP_CLUSTER_CONTROLLERS $TEMP_CLUSTER_WORKERS $TEMP_CLUSTER_LIST" EXIT

# First pass: Classify VMs by cluster and node type, write to temp files
CURRENT_CLUSTER=""
CONTROLLER_COUNT=0
WORKER_COUNT=0

while IFS= read -r vm_json; do
    if [ -z "$vm_json" ] || [ "$vm_json" = "null" ] || [ "$vm_json" = "" ]; then
        continue
    fi
    
    # Validate JSON before parsing
    if ! echo "$vm_json" | jq -e '.' >/dev/null 2>&1; then
        continue
    fi
    
    # Extract cluster name
    CLUSTER_NAME=$(echo "$vm_json" | jq -r '.metadata.categories.KubernetesClusterName // "unknown"' 2>/dev/null || echo "unknown")
    
    VM_NAME=$(echo "$vm_json" | jq -r '.spec.name // .status.name // "unknown"' 2>/dev/null || echo "unknown")
    
    # Track unique clusters
    if [ "$CLUSTER_NAME" != "$CURRENT_CLUSTER" ]; then
        if [ -n "$CURRENT_CLUSTER" ]; then
            echo "$CURRENT_CLUSTER" >> "$TEMP_CLUSTER_LIST"
        fi
        CURRENT_CLUSTER="$CLUSTER_NAME"
    fi
    
    # Classify as worker (contains '-md-') or controller (doesn't contain '-md-')
    if [[ "$VM_NAME" == *"-md-"* ]]; then
        # Worker node - write cluster name and VM JSON to temp file
        echo "${CLUSTER_NAME}|${vm_json}" >> "$TEMP_CLUSTER_WORKERS"
        WORKER_COUNT=$((WORKER_COUNT + 1))
    else
        # Controller node - write cluster name and VM JSON to temp file
        echo "${CLUSTER_NAME}|${vm_json}" >> "$TEMP_CLUSTER_CONTROLLERS"
        CONTROLLER_COUNT=$((CONTROLLER_COUNT + 1))
    fi
done <<< "$SORTED_VMS"

# Add the last cluster to the list
if [ -n "$CURRENT_CLUSTER" ]; then
    echo "$CURRENT_CLUSTER" >> "$TEMP_CLUSTER_LIST"
fi

# Get unique sorted cluster list
UNIQUE_CLUSTERS=$(sort -u "$TEMP_CLUSTER_LIST" 2>/dev/null)

# Second pass: Output results grouped by cluster, then by node type
FIRST_CLUSTER=true
while IFS= read -r CLUSTER_NAME; do
    if [ -z "$CLUSTER_NAME" ]; then
        continue
    fi
    
    if [ "$FIRST_CLUSTER" != true ]; then
        echo ""
    fi
    echo "$CLUSTER_NAME"
    FIRST_CLUSTER=false
    
    # Output controller nodes for this cluster
    echo "|_Controller Nodes"
    CLUSTER_CONTROLLERS=$(grep "^${CLUSTER_NAME}|" "$TEMP_CLUSTER_CONTROLLERS" 2>/dev/null | cut -d'|' -f2-)
    if [ -n "$CLUSTER_CONTROLLERS" ]; then
        while IFS= read -r vm_json; do
            if [ -z "$vm_json" ] || [ "$vm_json" = "null" ] || [ "$vm_json" = "" ]; then
                continue
            fi
            
            VM_UUID=$(echo "$vm_json" | jq -r '.metadata.uuid // empty' 2>/dev/null || echo "")
            VM_NAME=$(echo "$vm_json" | jq -r '.spec.name // .status.name // "unknown"' 2>/dev/null || echo "unknown")
            
            # Extract CPU and memory
            VM_CPU=$(echo "$vm_json" | jq -r '.spec.resources.num_sockets // 0' 2>/dev/null || echo "0")
            VM_MEMORY_MIB=$(echo "$vm_json" | jq -r '.spec.resources.memory_size_mib // 0' 2>/dev/null || echo "0")
            VM_MEMORY_GB=$(echo "$VM_MEMORY_MIB" | awk '{printf "%.2f", $1/1024}')
            
            echo "|  |_$VM_NAME (vCPU: $VM_CPU | Memory: $VM_MEMORY_GB GB)"
            
            # Find PVCs for this VM
            VM_PVCS=$(grep "^${VM_UUID}|" "$TEMP_PVC_MAP" | cut -d'|' -f2 | sort)
            
            if [ -n "$VM_PVCS" ]; then
                while IFS= read -r pvc_name; do
                    if [ -n "$pvc_name" ]; then
                        echo "|     |_$pvc_name"
                    fi
                done <<< "$VM_PVCS"
            fi
        done <<< "$CLUSTER_CONTROLLERS"
    else
        echo "|   |_(none found)"
    fi
    
    # Output worker nodes for this cluster
    echo "|_Worker Nodes"
    CLUSTER_WORKERS=$(grep "^${CLUSTER_NAME}|" "$TEMP_CLUSTER_WORKERS" 2>/dev/null | cut -d'|' -f2-)
    if [ -n "$CLUSTER_WORKERS" ]; then
        while IFS= read -r vm_json; do
            if [ -z "$vm_json" ] || [ "$vm_json" = "null" ] || [ "$vm_json" = "" ]; then
                continue
            fi
            
            VM_UUID=$(echo "$vm_json" | jq -r '.metadata.uuid // empty' 2>/dev/null || echo "")
            VM_NAME=$(echo "$vm_json" | jq -r '.spec.name // .status.name // "unknown"' 2>/dev/null || echo "unknown")
            
            # Extract CPU and memory
            VM_CPU=$(echo "$vm_json" | jq -r '.spec.resources.num_sockets // 0' 2>/dev/null || echo "0")
            VM_MEMORY_MIB=$(echo "$vm_json" | jq -r '.spec.resources.memory_size_mib // 0' 2>/dev/null || echo "0")
            VM_MEMORY_GB=$(echo "$VM_MEMORY_MIB" | awk '{printf "%.2f", $1/1024}')
            
            echo "   |_$VM_NAME (vCPU: $VM_CPU | Memory: $VM_MEMORY_GB GB)"
            
            # Find PVCs for this VM
            VM_PVCS=$(grep "^${VM_UUID}|" "$TEMP_PVC_MAP" | cut -d'|' -f2 | sort)
            
            if [ -n "$VM_PVCS" ]; then
                while IFS= read -r pvc_name; do
                    if [ -n "$pvc_name" ]; then
                        echo "      |_$pvc_name"
                    fi
                done <<< "$VM_PVCS"
            fi
        done <<< "$CLUSTER_WORKERS"
    else
        echo "   |_(none found)"
    fi
done <<< "$UNIQUE_CLUSTERS"

echo ""
echo "=========================================="
# Count clusters and VMs properly from the stream
CLUSTER_COUNT=$(echo "$K8S_VMS" | jq -s -r '.[] | .metadata.categories.KubernetesClusterName // "unknown"' | sort -u | wc -l | tr -d ' ')
VM_COUNT=$(echo "$K8S_VMS" | grep -c '^{' || echo "0")

# CONTROLLER_COUNT and WORKER_COUNT are already calculated during classification
echo "Summary:"
echo "  Clusters: $CLUSTER_COUNT"
echo "  Total VMs: $VM_COUNT"
echo "  Controller nodes: $CONTROLLER_COUNT"
echo "  Worker nodes: $WORKER_COUNT"
echo "  PVCs attached to these VMs: $TOTAL_PVCS"
echo "=========================================="

