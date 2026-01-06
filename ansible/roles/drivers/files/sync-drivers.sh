#!/bin/bash
# GPU Driver Sync Script
#
# Syncs GPU drivers from the Proxmox host to NAS storage for VM access.
# Triggered automatically via systemd path unit when drivers are updated.
#
# Usage:
#   sync-drivers.sh [--force] [--dry-run]
#
# Environment:
#   DRIVERS_NFS_PATH - NFS path for drivers (default: /mnt/gaming-drivers)
#   NVIDIA_DRIVER_DIR - Local NVIDIA driver directory

set -euo pipefail

# Configuration
DRIVERS_NFS_PATH="${DRIVERS_NFS_PATH:-/mnt/gaming-drivers}"
NVIDIA_DRIVER_DIR="${NVIDIA_DRIVER_DIR:-/opt/nvidia-vgpu}"
INTEL_FIRMWARE_DIR="/lib/firmware/i915"
STATE_FILE="/var/lib/gpu-manager/driver-sync-state.json"
LOCK_FILE="/var/lock/driver-sync.lock"

# Options
FORCE=false
DRY_RUN=false

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    logger -t "driver-sync" "$1" 2>/dev/null || true
}

error() {
    log "ERROR: $1"
    exit 1
}

# Acquire lock to prevent concurrent syncs
acquire_lock() {
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        log "Another sync is in progress, exiting"
        exit 0
    fi
}

# Check if NFS mount is available
check_nfs() {
    if ! mountpoint -q "$DRIVERS_NFS_PATH" 2>/dev/null; then
        # Try to mount
        mount "$DRIVERS_NFS_PATH" 2>/dev/null || error "NFS mount not available at $DRIVERS_NFS_PATH"
    fi
}

# Get current driver version
get_nvidia_version() {
    if [[ -f "${NVIDIA_DRIVER_DIR}/version" ]]; then
        cat "${NVIDIA_DRIVER_DIR}/version"
    elif command -v nvidia-smi &>/dev/null; then
        nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1
    else
        echo "unknown"
    fi
}

# Get last synced version
get_last_synced_version() {
    if [[ -f "$STATE_FILE" ]]; then
        jq -r '.nvidia_version // "none"' "$STATE_FILE" 2>/dev/null
    else
        echo "none"
    fi
}

# Update state file
update_state() {
    local nvidia_version="$1"
    local intel_version="${2:-unknown}"

    mkdir -p "$(dirname "$STATE_FILE")"
    cat > "$STATE_FILE" <<EOF
{
    "nvidia_version": "$nvidia_version",
    "intel_version": "$intel_version",
    "last_sync": "$(date -Iseconds)",
    "hostname": "$(hostname)"
}
EOF
}

# Sync NVIDIA drivers
sync_nvidia() {
    local current_version=$(get_nvidia_version)
    local last_version=$(get_last_synced_version)

    log "NVIDIA: Current version=$current_version, Last synced=$last_version"

    if [[ "$current_version" == "$last_version" ]] && ! $FORCE; then
        log "NVIDIA: Already synced, skipping"
        return 0
    fi

    local dest_dir="${DRIVERS_NFS_PATH}/nvidia"

    if $DRY_RUN; then
        log "[DRY-RUN] Would sync NVIDIA drivers to $dest_dir"
        return 0
    fi

    # Create destination directories
    mkdir -p "${dest_dir}/linux" "${dest_dir}/windows"

    # Sync Linux guest drivers
    if [[ -d "${NVIDIA_DRIVER_DIR}/guest" ]]; then
        log "Syncing Linux guest drivers..."
        for driver in "${NVIDIA_DRIVER_DIR}/guest/"NVIDIA-Linux-*.run; do
            [[ -f "$driver" ]] || continue
            local filename=$(basename "$driver")
            cp -v "$driver" "${dest_dir}/linux/${filename}"
            chmod 644 "${dest_dir}/linux/${filename}"
        done
    fi

    # Sync Windows guest drivers
    if [[ -d "${NVIDIA_DRIVER_DIR}/guest-windows" ]]; then
        log "Syncing Windows guest drivers..."
        for driver in "${NVIDIA_DRIVER_DIR}/guest-windows/"*.exe; do
            [[ -f "$driver" ]] || continue
            local filename=$(basename "$driver")
            cp -v "$driver" "${dest_dir}/windows/${filename}"
            chmod 644 "${dest_dir}/windows/${filename}"
        done
    fi

    # Create version marker
    echo "$current_version" > "${dest_dir}/VERSION"
    echo "$(date -Iseconds)" > "${dest_dir}/LAST_UPDATED"

    log "NVIDIA: Sync complete (version $current_version)"
    return 0
}

# Sync Intel firmware
sync_intel() {
    local dest_dir="${DRIVERS_NFS_PATH}/intel"

    if [[ ! -d "$INTEL_FIRMWARE_DIR" ]]; then
        log "Intel: No firmware directory found, skipping"
        return 0
    fi

    if $DRY_RUN; then
        log "[DRY-RUN] Would sync Intel firmware to $dest_dir"
        return 0
    fi

    mkdir -p "${dest_dir}/firmware"

    log "Syncing Intel i915 firmware..."
    rsync -av --delete "${INTEL_FIRMWARE_DIR}/" "${dest_dir}/firmware/"

    # Get kernel version for reference
    local kernel_version=$(uname -r)
    echo "$kernel_version" > "${dest_dir}/KERNEL_VERSION"
    echo "$(date -Iseconds)" > "${dest_dir}/LAST_UPDATED"

    log "Intel: Sync complete"
    return 0
}

# Create driver inventory
create_inventory() {
    local inventory="${DRIVERS_NFS_PATH}/inventory.json"

    if $DRY_RUN; then
        log "[DRY-RUN] Would create inventory at $inventory"
        return 0
    fi

    log "Creating driver inventory..."

    local nvidia_files=()
    local intel_files=()

    # List NVIDIA drivers
    if [[ -d "${DRIVERS_NFS_PATH}/nvidia/linux" ]]; then
        while IFS= read -r -d '' file; do
            nvidia_files+=("$(basename "$file")")
        done < <(find "${DRIVERS_NFS_PATH}/nvidia/linux" -name "*.run" -print0 2>/dev/null)
    fi

    # List Intel firmware
    if [[ -d "${DRIVERS_NFS_PATH}/intel/firmware" ]]; then
        local intel_count=$(find "${DRIVERS_NFS_PATH}/intel/firmware" -type f | wc -l)
        intel_files+=("$intel_count firmware files")
    fi

    # Generate inventory JSON
    cat > "$inventory" <<EOF
{
    "generated": "$(date -Iseconds)",
    "source_host": "$(hostname)",
    "nvidia": {
        "version": "$(get_nvidia_version)",
        "linux_drivers": $(printf '%s\n' "${nvidia_files[@]}" | jq -R . | jq -s .),
        "windows_drivers": $(find "${DRIVERS_NFS_PATH}/nvidia/windows" -name "*.exe" -exec basename {} \; 2>/dev/null | jq -R . | jq -s .)
    },
    "intel": {
        "kernel_version": "$(cat "${DRIVERS_NFS_PATH}/intel/KERNEL_VERSION" 2>/dev/null || echo 'unknown')",
        "firmware_count": $(find "${DRIVERS_NFS_PATH}/intel/firmware" -type f 2>/dev/null | wc -l)
    }
}
EOF

    log "Inventory created at $inventory"
}

# Usage help
show_help() {
    cat <<EOF
GPU Driver Sync Utility

Syncs GPU drivers from Proxmox host to NAS for VM access.

Usage:
  $0 [options]

Options:
  --force       Force sync even if versions match
  --dry-run     Show what would be done without making changes
  --nvidia      Sync only NVIDIA drivers
  --intel       Sync only Intel firmware
  --help        Show this help

Configuration (environment variables):
  DRIVERS_NFS_PATH   NFS mount for drivers (default: /mnt/gaming-drivers)
  NVIDIA_DRIVER_DIR  Local NVIDIA driver location (default: /opt/nvidia-vgpu)

EOF
}

# Parse arguments
SYNC_NVIDIA=true
SYNC_INTEL=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)
            FORCE=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --nvidia)
            SYNC_NVIDIA=true
            SYNC_INTEL=false
            shift
            ;;
        --intel)
            SYNC_NVIDIA=false
            SYNC_INTEL=true
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# Main
log "=== Driver Sync Started ==="

acquire_lock
check_nfs

nvidia_version="unknown"

if $SYNC_NVIDIA; then
    sync_nvidia
    nvidia_version=$(get_nvidia_version)
fi

if $SYNC_INTEL; then
    sync_intel
fi

create_inventory

if ! $DRY_RUN; then
    update_state "$nvidia_version"
fi

log "=== Driver Sync Complete ==="
