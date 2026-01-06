#!/bin/bash
# GPU Preemption Script
#
# Gracefully stops background VMs to free GPU resources for gaming.
#
# Usage:
#   gpu-preempt.sh <requesting_vmid>  - Preempt background VMs for game
#   gpu-preempt.sh --list             - List preemptable VMs

set -e

STATE_DIR="/var/lib/gpu-manager"
ALLOCATIONS_FILE="${STATE_DIR}/allocations.json"
SHUTDOWN_TIMEOUT=30  # seconds

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a /var/log/gpu-manager.log
}

error() {
    echo "[ERROR] $1" >&2
    exit 1
}

# Find background VMs
find_background_vms() {
    if [[ -f "$ALLOCATIONS_FILE" ]]; then
        jq -r '.allocations | to_entries[] | select(.value.priority == "background") | .key' "$ALLOCATIONS_FILE"
    fi
}

# List preemptable VMs
list_preemptable() {
    echo "Preemptable (background) VMs:"
    echo "-----------------------------"

    local vms=$(find_background_vms)
    if [[ -z "$vms" ]]; then
        echo "  None"
        return
    fi

    while read -r vmid; do
        local profile=$(jq -r --arg vmid "$vmid" '.allocations[$vmid].profile' "$ALLOCATIONS_FILE")
        local allocated=$(jq -r --arg vmid "$vmid" '.allocations[$vmid].allocated_at' "$ALLOCATIONS_FILE")
        echo "  VM $vmid: $profile (allocated: $allocated)"
    done <<< "$vms"
}

# Gracefully shutdown a VM
shutdown_vm() {
    local vmid="$1"

    log "Initiating graceful shutdown of VM $vmid"

    # Send shutdown signal via qm
    if ! qm shutdown "$vmid" --timeout "$SHUTDOWN_TIMEOUT" 2>/dev/null; then
        log "Graceful shutdown failed, forcing stop"
        qm stop "$vmid" 2>/dev/null || true
    fi

    # Remove from allocations
    /usr/local/bin/gpu-allocate.sh release "$vmid"

    log "VM $vmid stopped and GPU released"
}

# Preempt background VMs for a game request
preempt_for_game() {
    local requesting_vmid="$1"

    log "Preemption requested by VM $requesting_vmid"

    local background_vms=$(find_background_vms)
    if [[ -z "$background_vms" ]]; then
        echo '{"status": "no_preemptable", "message": "No background VMs to preempt"}'
        return 1
    fi

    local preempted=()
    while read -r vmid; do
        log "Preempting background VM $vmid for game VM $requesting_vmid"
        shutdown_vm "$vmid"
        preempted+=("$vmid")
    done <<< "$background_vms"

    echo '{"status": "preempted", "vms": ['$(printf '"%s",' "${preempted[@]}" | sed 's/,$//')']}'
}

# Main
case "${1:-}" in
    --list|-l)
        list_preemptable
        ;;
    --help|-h)
        echo "GPU Preemption Manager"
        echo ""
        echo "Usage:"
        echo "  $0 <requesting_vmid>  - Preempt background VMs"
        echo "  $0 --list             - List preemptable VMs"
        echo ""
        echo "Background VMs (priority=background) will be gracefully"
        echo "shut down to free GPU resources for gaming VMs."
        ;;
    *)
        if [[ -z "$1" ]]; then
            list_preemptable
        else
            preempt_for_game "$1"
        fi
        ;;
esac
