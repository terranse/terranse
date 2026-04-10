#!/bin/bash
# GPU Slice Reconfiguration Script
#
# Dynamically changes vGPU slice configuration with safety gate.
# Handles the full lifecycle: shutdown VMs → destroy mdevs → verify release →
# create new mdevs → reconfigure VMs → start VMs.
#
# IMPORTANT: NVIDIA A5000 requires homogeneous vGPU slices. All active slices
# must be the same type. Changing types requires destroying ALL existing slices.
#
# Usage:
#   gpu-reconfig.sh reconfigure <profile> <num_slices>
#   gpu-reconfig.sh can-reconfigure <profile> <num_slices>
#   gpu-reconfig.sh current
#   gpu-reconfig.sh destroy-all

set -euo pipefail

# Configuration
CONFIG_FILE="${GPU_PROFILES_CONF:-/etc/gpu-manager/gpu-profiles.conf}"
VM_MAP_FILE="${VM_MAP_FILE:-/etc/gpu-manager/vm-map.json}"
ALLOCATIONS_FILE="${ALLOCATIONS_FILE:-/var/lib/gpu-manager/allocations.json}"
LOCK_FILE="/var/lib/gpu-manager/reconfig.lock"
STATE_FILE="/var/lib/gpu-manager/reconfig-state.json"
MDEV_RELEASE_TIMEOUT="${MDEV_RELEASE_TIMEOUT:-30}"
VM_SHUTDOWN_TIMEOUT="${VM_SHUTDOWN_TIMEOUT:-60}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [gpu-reconfig] $1" | tee -a /var/log/gpu-manager.log
}

error() {
    log "ERROR: $1"
    echo '{"status": "error", "message": "'"$1"'"}' >&2
    exit 1
}

# Parse gpu-profiles.conf for NVIDIA section
parse_config() {
    local pci_addr mdev_type vram_mb max_instances

    pci_addr=$(grep -E '^pci_address=' "$CONFIG_FILE" | head -1 | cut -d= -f2)
    NVIDIA_PCI_ADDRESS="${pci_addr:-0000:41:00.0}"

    # Build profile lookup from config (format: name=vram_mb:max_instances:mdev_type)
    declare -gA PROFILE_VRAM PROFILE_MAX PROFILE_MDEV
    while IFS='=' read -r name value; do
        [[ "$name" =~ ^Q- ]] || continue
        IFS=':' read -r vram_mb max_instances mdev_type <<< "$value"
        PROFILE_VRAM["$name"]="$vram_mb"
        PROFILE_MAX["$name"]="$max_instances"
        PROFILE_MDEV["$name"]="$mdev_type"
    done < <(grep -E '^Q-' "$CONFIG_FILE")
}

# Get all currently active mdev UUIDs
list_mdev_uuids() {
    local mdev_dir="/sys/bus/mdev/devices"
    if [[ -d "$mdev_dir" ]]; then
        ls "$mdev_dir" 2>/dev/null || true
    fi
}

# Get current mdev type (all must be the same on A5000)
current_mdev_type() {
    local uuid
    for uuid in $(list_mdev_uuids); do
        local type_path="/sys/bus/mdev/devices/$uuid/mdev_type/name"
        if [[ -f "$type_path" ]]; then
            cat "$type_path"
            return
        fi
    done
    echo "none"
}

# Get current slice count
current_slice_count() {
    list_mdev_uuids | wc -w
}

# Reverse-lookup: mdev type name → profile name (e.g., nvidia-259 → Q-8C)
mdev_type_to_profile() {
    local target_type="$1"
    local name
    for name in "${!PROFILE_MDEV[@]}"; do
        if [[ "${PROFILE_MDEV[$name]}" == "$target_type" ]]; then
            echo "$name"
            return
        fi
    done
    echo "unknown"
}

# Get all gaming VM IDs from vm-map.json
get_all_gaming_vmids() {
    if [[ -f "$VM_MAP_FILE" ]]; then
        jq -r '.[] | tostring' "$VM_MAP_FILE" 2>/dev/null
    fi
}

# Shut down all gaming VMs cleanly
shutdown_all_gaming_vms() {
    local vmid status shutdown_failed=0

    for vmid in $(get_all_gaming_vmids); do
        status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}' || echo "unknown")
        case "$status" in
            running)
                log "Shutting down VM $vmid (clean shutdown, timeout ${VM_SHUTDOWN_TIMEOUT}s)"
                if ! qm shutdown "$vmid" --timeout "$VM_SHUTDOWN_TIMEOUT" 2>/dev/null; then
                    log "Clean shutdown failed for VM $vmid, forcing stop"
                    qm stop "$vmid" --timeout 15 2>/dev/null || true
                fi
                ;;
            suspended)
                log "Resuming suspended VM $vmid before shutdown"
                qm resume "$vmid" 2>/dev/null || true
                sleep 5
                qm shutdown "$vmid" --timeout "$VM_SHUTDOWN_TIMEOUT" 2>/dev/null || \
                    qm stop "$vmid" --timeout 15 2>/dev/null || true
                ;;
            stopped)
                log "VM $vmid already stopped"
                ;;
            *)
                log "VM $vmid in unknown state: $status"
                ;;
        esac
    done

    # Verify all VMs are stopped
    for vmid in $(get_all_gaming_vmids); do
        status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}' || echo "unknown")
        if [[ "$status" != "stopped" ]]; then
            log "VM $vmid still in state: $status after shutdown attempt"
            shutdown_failed=1
        fi
    done

    return "$shutdown_failed"
}

# Destroy all mdev instances
destroy_all_mdevs() {
    local uuid
    for uuid in $(list_mdev_uuids); do
        log "Destroying mdev $uuid"
        echo 1 > "/sys/bus/mdev/devices/$uuid/remove" 2>/dev/null || {
            log "Failed to remove mdev $uuid"
            return 1
        }
    done
    return 0
}

# Verify all mdev instances are released (with timeout)
verify_mdev_release() {
    local elapsed=0
    while [[ "$elapsed" -lt "$MDEV_RELEASE_TIMEOUT" ]]; do
        local count
        count=$(list_mdev_uuids | wc -w)
        if [[ "$count" -eq 0 ]]; then
            log "All mdev instances released"
            return 0
        fi
        log "Waiting for mdev release... ($count remaining, ${elapsed}s/${MDEV_RELEASE_TIMEOUT}s)"
        sleep 2
        elapsed=$((elapsed + 2))
    done

    log "TIMEOUT: mdev instances not released after ${MDEV_RELEASE_TIMEOUT}s"
    return 1
}

# Create new mdev instances for a given profile
create_mdevs() {
    local profile="$1"
    local count="$2"
    local mdev_type="${PROFILE_MDEV[$profile]}"
    local create_path="/sys/class/mdev_bus/${NVIDIA_PCI_ADDRESS}/mdev_supported_types/${mdev_type}/create"
    local i uuid

    if [[ ! -d "$(dirname "$create_path")" ]]; then
        error "mdev type path does not exist: $(dirname "$create_path"). Is the NVIDIA driver loaded?"
    fi

    for ((i = 0; i < count; i++)); do
        uuid=$(cat /proc/sys/kernel/random/uuid)
        log "Creating mdev $uuid (type: $mdev_type, profile: $profile, $((i+1))/$count)"
        echo "$uuid" > "$create_path" 2>/dev/null || {
            error "Failed to create mdev instance $((i+1))/$count"
        }
    done

    log "Created $count mdev instances of type $mdev_type ($profile)"
}

# Reconfigure VMs to use new mdev UUIDs
reconfigure_vms() {
    local profile="$1"
    local mdev_uuids=()
    local vmids=()
    local i

    # Collect new mdev UUIDs
    while IFS= read -r uuid; do
        [[ -n "$uuid" ]] && mdev_uuids+=("$uuid")
    done < <(list_mdev_uuids)

    # Collect VM IDs
    while IFS= read -r vmid; do
        [[ -n "$vmid" ]] && vmids+=("$vmid")
    done < <(get_all_gaming_vmids)

    # Assign one mdev per VM (up to available mdevs)
    for ((i = 0; i < ${#mdev_uuids[@]} && i < ${#vmids[@]}; i++)); do
        local vmid="${vmids[$i]}"
        local uuid="${mdev_uuids[$i]}"
        log "Assigning mdev $uuid to VM $vmid"
        qm set "$vmid" --hostpci0 "${NVIDIA_PCI_ADDRESS},mdev=${uuid}" 2>/dev/null || {
            log "Failed to assign mdev to VM $vmid (non-fatal, VM may need manual config)"
        }
    done
}

# Save reconfig state for recovery
save_state() {
    local status="$1"
    local profile="${2:-}"
    local count="${3:-0}"
    jq -n \
        --arg status "$status" \
        --arg profile "$profile" \
        --argjson count "$count" \
        --arg timestamp "$(date -Iseconds)" \
        '{status: $status, profile: $profile, count: $count, timestamp: $timestamp}' \
        > "$STATE_FILE"
}

# Acquire exclusive lock for reconfiguration
acquire_reconfig_lock() {
    exec 201>"$LOCK_FILE"
    if ! flock -n -w 10 201; then
        error "Another reconfiguration is in progress (lock: $LOCK_FILE)"
    fi
}

# Main reconfiguration flow with safety gate
do_reconfigure() {
    local target_profile="$1"
    local num_slices="$2"

    # Validate inputs
    [[ -n "${PROFILE_MDEV[$target_profile]+x}" ]] || \
        error "Unknown profile: $target_profile. Valid: ${!PROFILE_MDEV[*]}"
    [[ "$num_slices" -gt 0 && "$num_slices" -le "${PROFILE_MAX[$target_profile]}" ]] || \
        error "Invalid slice count $num_slices for $target_profile (max: ${PROFILE_MAX[$target_profile]})"

    # Check if already in the desired configuration
    local current_type current_count current_profile
    current_type=$(current_mdev_type)
    current_count=$(current_slice_count)
    current_profile=$(mdev_type_to_profile "$current_type")

    if [[ "$current_profile" == "$target_profile" && "$current_count" -eq "$num_slices" ]]; then
        log "Already in desired configuration: ${target_profile} x${num_slices}"
        jq -n --arg profile "$target_profile" --argjson count "$num_slices" \
            '{status: "already_configured", profile: $profile, count: $count}'
        return 0
    fi

    acquire_reconfig_lock

    log "=== Starting reconfiguration: ${current_profile} x${current_count} → ${target_profile} x${num_slices} ==="
    save_state "in_progress" "$target_profile" "$num_slices"

    # Step 1: Shutdown all gaming VMs
    log "Step 1/5: Shutting down all gaming VMs"
    if ! shutdown_all_gaming_vms; then
        save_state "failed_shutdown"
        error "Failed to shut down all gaming VMs. Aborting reconfiguration."
    fi

    # Step 2: Destroy existing mdev instances
    log "Step 2/5: Destroying existing mdev instances"
    if ! destroy_all_mdevs; then
        save_state "failed_mdev_destroy"
        error "Failed to destroy mdev instances. VMs are stopped. Manual intervention required."
    fi

    # Step 3: SAFETY GATE — verify mdev release
    log "Step 3/5: Verifying mdev release (timeout: ${MDEV_RELEASE_TIMEOUT}s)"
    if ! verify_mdev_release; then
        save_state "failed_mdev_release"
        local remaining
        remaining=$(list_mdev_uuids | wc -w)
        error "SAFETY GATE: mdev instances not fully released ($remaining remaining). Aborting. VMs stopped, GPU may need host reboot."
    fi

    # Step 4: Create new mdev instances
    log "Step 4/5: Creating $num_slices x $target_profile mdev instances"
    if ! create_mdevs "$target_profile" "$num_slices"; then
        save_state "failed_mdev_create"
        error "Failed to create new mdev instances. VMs stopped."
    fi

    # Step 5: Reconfigure VMs with new mdev UUIDs
    log "Step 5/5: Reconfiguring VMs with new mdev assignments"
    reconfigure_vms "$target_profile"

    # Clear allocation state (VMs will re-register on start)
    jq '.allocations = {} | .last_updated = now | todate' "$ALLOCATIONS_FILE" > "${ALLOCATIONS_FILE}.tmp" \
        && mv "${ALLOCATIONS_FILE}.tmp" "$ALLOCATIONS_FILE" 2>/dev/null || true

    save_state "completed" "$target_profile" "$num_slices"
    log "=== Reconfiguration complete: ${target_profile} x${num_slices} ==="

    jq -n --arg profile "$target_profile" --argjson count "$num_slices" \
        '{status: "reconfigured", profile: $profile, count: $count}'
}

# Check if reconfiguration is possible without doing it
do_can_reconfigure() {
    local target_profile="$1"
    local num_slices="$2"

    [[ -n "${PROFILE_MDEV[$target_profile]+x}" ]] || \
        { jq -n '{possible: false, reason: "unknown profile"}'; return; }
    [[ "$num_slices" -gt 0 && "$num_slices" -le "${PROFILE_MAX[$target_profile]}" ]] || \
        { jq -n '{possible: false, reason: "invalid slice count"}'; return; }

    local current_type current_count current_profile
    current_type=$(current_mdev_type)
    current_count=$(current_slice_count)
    current_profile=$(mdev_type_to_profile "$current_type")

    if [[ "$current_profile" == "$target_profile" && "$current_count" -eq "$num_slices" ]]; then
        jq -n '{possible: true, reason: "already_configured", needs_reconfig: false}'
    else
        jq -n --arg from "${current_profile} x${current_count}" \
              --arg to "${target_profile} x${num_slices}" \
              '{possible: true, reason: "requires VM shutdown and mdev rebuild", needs_reconfig: true, from: $from, to: $to}'
    fi
}

# Show current GPU slice configuration
do_current() {
    local current_type current_count current_profile
    current_type=$(current_mdev_type)
    current_count=$(current_slice_count)
    current_profile=$(mdev_type_to_profile "$current_type")

    local state_status="unknown"
    if [[ -f "$STATE_FILE" ]]; then
        state_status=$(jq -r '.status // "unknown"' "$STATE_FILE")
    fi

    jq -n \
        --arg profile "$current_profile" \
        --arg mdev_type "$current_type" \
        --argjson count "$current_count" \
        --arg last_reconfig_status "$state_status" \
        '{profile: $profile, mdev_type: $mdev_type, slice_count: $count, last_reconfig_status: $last_reconfig_status}'
}

# --- Main ---
parse_config

action="${1:-}"
case "$action" in
    reconfigure)
        do_reconfigure "${2:?'profile required (e.g., Q-12C)'}" "${3:?'num_slices required (e.g., 2)'}"
        ;;
    can-reconfigure)
        do_can_reconfigure "${2:?'profile required'}" "${3:?'num_slices required'}"
        ;;
    current)
        do_current
        ;;
    destroy-all)
        acquire_reconfig_lock
        log "Manual destroy-all requested"
        shutdown_all_gaming_vms || true
        destroy_all_mdevs || error "Failed to destroy mdevs"
        verify_mdev_release || error "mdevs not fully released"
        save_state "destroyed"
        echo '{"status": "all_mdevs_destroyed"}'
        ;;
    *)
        echo "GPU Slice Reconfiguration (with safety gate)"
        echo ""
        echo "Usage:"
        echo "  $0 reconfigure <profile> <num_slices>  - Reconfigure GPU slices"
        echo "  $0 can-reconfigure <profile> <num>     - Check if reconfig is possible"
        echo "  $0 current                             - Show current configuration"
        echo "  $0 destroy-all                         - Destroy all mdevs (emergency)"
        echo ""
        echo "Profiles: ${!PROFILE_MDEV[*]}"
        echo ""
        echo "Examples:"
        echo "  $0 reconfigure Q-12C 2    # 2 players, 12GB each"
        echo "  $0 reconfigure Q-24C 1    # 1 player, full GPU"
        echo "  $0 reconfigure Q-8C 3     # 3 players, 8GB each"
        exit 1
        ;;
esac
