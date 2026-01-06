#!/bin/bash
# VM Snapshot Management Script
#
# Manages ZFS snapshots for gaming VMs for instant resume functionality.
#
# Usage:
#   vm-snapshot.sh <vmid> create [name]    - Create snapshot
#   vm-snapshot.sh <vmid> rollback [name]  - Rollback to snapshot
#   vm-snapshot.sh <vmid> list             - List snapshots
#   vm-snapshot.sh <vmid> delete <name>    - Delete snapshot

set -e

# Configuration
ZFS_POOL="${ZFS_POOL:-games}"
VMS_DATASET="${ZFS_POOL}/vms"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a /var/log/gpu-manager.log
}

error() {
    echo "[ERROR] $1" >&2
    exit 1
}

# Get VM disk path from Proxmox
get_vm_disk() {
    local vmid="$1"

    # Try to get disk from qm config
    local disk=$(qm config "$vmid" 2>/dev/null | grep -E "^scsi0:" | sed 's/.*://' | cut -d',' -f1)

    if [[ -z "$disk" ]]; then
        # Fall back to standard naming
        disk="${VMS_DATASET}/${vmid}"
    fi

    # Check if it's a ZFS zvol
    if [[ "$disk" =~ ^${ZFS_POOL}/ ]]; then
        echo "$disk"
    else
        # Assume standard naming convention
        echo "${VMS_DATASET}/vm-${vmid}-disk-0"
    fi
}

# Create snapshot
create_snapshot() {
    local vmid="$1"
    local name="${2:-clean-boot}"
    local zvol=$(get_vm_disk "$vmid")

    log "Creating snapshot ${zvol}@${name}"

    # Check if VM is running
    local status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
    if [[ "$status" == "running" ]]; then
        # Freeze filesystem before snapshot (if guest agent available)
        qm guest exec "$vmid" -- sync 2>/dev/null || true
        qm guest exec "$vmid" -- fsfreeze --freeze / 2>/dev/null || true
    fi

    # Create ZFS snapshot
    zfs snapshot "${zvol}@${name}"

    if [[ "$status" == "running" ]]; then
        # Unfreeze filesystem
        qm guest exec "$vmid" -- fsfreeze --unfreeze / 2>/dev/null || true
    fi

    log "Snapshot created: ${zvol}@${name}"
    echo '{"status": "created", "snapshot": "'${zvol}@${name}'"}'
}

# Rollback to snapshot
rollback_snapshot() {
    local vmid="$1"
    local name="${2:-clean-boot}"
    local zvol=$(get_vm_disk "$vmid")

    log "Rolling back ${zvol} to snapshot @${name}"

    # VM must be stopped for rollback
    local status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
    if [[ "$status" == "running" ]]; then
        log "Stopping VM $vmid for rollback"
        qm stop "$vmid" --timeout 30
    fi

    # Perform rollback
    zfs rollback "${zvol}@${name}"

    log "Rollback complete: ${zvol}@${name}"
    echo '{"status": "rolled_back", "snapshot": "'${zvol}@${name}'"}'
}

# List snapshots
list_snapshots() {
    local vmid="$1"
    local zvol=$(get_vm_disk "$vmid")

    echo "Snapshots for VM $vmid (${zvol}):"
    echo "-----------------------------------"

    zfs list -t snapshot -o name,creation,used,refer -r "$zvol" 2>/dev/null || echo "No snapshots found"
}

# Delete snapshot
delete_snapshot() {
    local vmid="$1"
    local name="$2"
    local zvol=$(get_vm_disk "$vmid")

    [[ -z "$name" ]] && error "Snapshot name required"

    log "Deleting snapshot ${zvol}@${name}"
    zfs destroy "${zvol}@${name}"

    log "Snapshot deleted: ${zvol}@${name}"
    echo '{"status": "deleted", "snapshot": "'${zvol}@${name}'"}'
}

# Main
vmid="${1:-}"
action="${2:-}"

[[ -z "$vmid" ]] && error "Usage: $0 <vmid> <action> [name]"

case "$action" in
    create)
        create_snapshot "$vmid" "${3:-clean-boot}"
        ;;
    rollback)
        rollback_snapshot "$vmid" "${3:-clean-boot}"
        ;;
    list)
        list_snapshots "$vmid"
        ;;
    delete)
        delete_snapshot "$vmid" "$3"
        ;;
    *)
        echo "VM Snapshot Manager"
        echo ""
        echo "Usage:"
        echo "  $0 <vmid> create [name]   - Create snapshot (default: clean-boot)"
        echo "  $0 <vmid> rollback [name] - Rollback to snapshot"
        echo "  $0 <vmid> list            - List all snapshots"
        echo "  $0 <vmid> delete <name>   - Delete snapshot"
        echo ""
        echo "Examples:"
        echo "  $0 105 create              - Create clean-boot snapshot"
        echo "  $0 105 rollback            - Restore to clean-boot"
        echo "  $0 105 create before-update"
        exit 1
        ;;
esac
