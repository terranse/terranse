#!/bin/bash
# GPU Allocation Script for Proxmox
#
# Manages NVIDIA vGPU and Intel SR-IOV allocation with priority handling.
# Uses file locking to prevent race conditions between concurrent requests.
#
# Usage:
#   gpu-allocate.sh request <vm_id> [profile]  - Request GPU for VM
#   gpu-allocate.sh release <vm_id>            - Release GPU from VM
#   gpu-allocate.sh check <profile>            - Check if profile is available
#
# Configuration:
#   /etc/gpu-manager/gpu-profiles.conf
#   /etc/gpu-manager/game-profiles.json
#
# State:
#   /var/lib/gpu-manager/allocations.json

set -e

# Configuration
CONFIG_DIR="/etc/gpu-manager"
STATE_DIR="/var/lib/gpu-manager"
PROFILES_CONF="${CONFIG_DIR}/gpu-profiles.conf"
GAME_PROFILES="${CONFIG_DIR}/game-profiles.json"
ALLOCATIONS_FILE="${STATE_DIR}/allocations.json"
LOCK_FILE="${STATE_DIR}/allocations.lock"
SESSION_STATE_DIR="/mnt/gaming/session-state"  # NFS shared from NAS
LOCK_TIMEOUT=30  # seconds to wait for lock

# NVIDIA A5000 configuration (24GB total)
NVIDIA_TOTAL_VRAM=24576  # MB
NVIDIA_PCI="0000:41:00.0"

# Profile VRAM requirements (MB)
declare -A PROFILE_VRAM=(
    ["Q-1C"]=1024
    ["Q-2C"]=2048
    ["Q-4C"]=4096
    ["Q-8C"]=8192
    ["Q-12C"]=12288
    ["Q-24C"]=24576
)

# Logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a /var/log/gpu-manager.log
}

error() {
    echo "[ERROR] $1" >&2
    log "ERROR: $1"
    exit 1
}

# File locking to prevent race conditions
# Uses flock for atomic operations on state file
LOCK_FD=200

acquire_lock() {
    # Ensure state directory exists
    mkdir -p "$STATE_DIR"

    # Open lock file on file descriptor 200
    exec 200>"$LOCK_FILE"

    # Try to acquire exclusive lock with timeout
    if ! flock -w "$LOCK_TIMEOUT" 200; then
        error "Failed to acquire lock after ${LOCK_TIMEOUT}s - another operation in progress?"
    fi
    log "Lock acquired"
}

release_lock() {
    flock -u 200 2>/dev/null || true
    log "Lock released"
}

# Ensure lock is released on exit
trap release_lock EXIT

# Initialize state file if needed
init_state() {
    if [[ ! -f "$ALLOCATIONS_FILE" ]]; then
        echo '{"allocations": {}, "last_updated": "'$(date -Iseconds)'"}' > "$ALLOCATIONS_FILE"
    fi
}

# Get current allocations
get_allocations() {
    jq -r '.allocations' "$ALLOCATIONS_FILE"
}

# Calculate used VRAM
get_used_vram() {
    local total=0
    for profile in $(jq -r '.allocations | to_entries[] | .value.profile' "$ALLOCATIONS_FILE" 2>/dev/null); do
        total=$((total + ${PROFILE_VRAM[$profile]:-0}))
    done
    echo $total
}

# Get available VRAM
get_available_vram() {
    local used=$(get_used_vram)
    echo $((NVIDIA_TOTAL_VRAM - used))
}

# Check if profile fits
profile_fits() {
    local profile="$1"
    local required=${PROFILE_VRAM[$profile]:-0}
    local available=$(get_available_vram)

    [[ $available -ge $required ]]
}

# Add allocation to state
add_allocation() {
    local vm_id="$1"
    local profile="$2"
    local priority="${3:-game}"

    jq --arg vm_id "$vm_id" \
       --arg profile "$profile" \
       --arg priority "$priority" \
       --arg timestamp "$(date -Iseconds)" \
       '.allocations[$vm_id] = {
           "profile": $profile,
           "priority": $priority,
           "allocated_at": $timestamp
       } | .last_updated = $timestamp' \
       "$ALLOCATIONS_FILE" > "${ALLOCATIONS_FILE}.tmp"

    mv "${ALLOCATIONS_FILE}.tmp" "$ALLOCATIONS_FILE"
}

# Remove allocation from state
remove_allocation() {
    local vm_id="$1"

    jq --arg vm_id "$vm_id" \
       --arg timestamp "$(date -Iseconds)" \
       'del(.allocations[$vm_id]) | .last_updated = $timestamp' \
       "$ALLOCATIONS_FILE" > "${ALLOCATIONS_FILE}.tmp"

    mv "${ALLOCATIONS_FILE}.tmp" "$ALLOCATIONS_FILE"
}

# Check if a VM has an active Sunshine session
has_active_session() {
    local vm_id="$1"
    local session_file

    # Look for session file by VM ID or hostname pattern
    for session_file in "${SESSION_STATE_DIR}"/*.session; do
        [[ -f "$session_file" ]] || continue

        local file_vm_id=$(jq -r '.vm_id // empty' "$session_file" 2>/dev/null)
        local status=$(jq -r '.status // empty' "$session_file" 2>/dev/null)

        if [[ "$file_vm_id" == "$vm_id" && "$status" == "active" ]]; then
            return 0
        fi
    done

    return 1
}

# Get all active sessions
get_active_sessions() {
    local sessions=()
    local session_file

    for session_file in "${SESSION_STATE_DIR}"/*.session; do
        [[ -f "$session_file" ]] || continue

        local status=$(jq -r '.status // empty' "$session_file" 2>/dev/null)
        if [[ "$status" == "active" ]]; then
            local vm_id=$(jq -r '.vm_id // empty' "$session_file" 2>/dev/null)
            sessions+=("$vm_id")
        fi
    done

    echo "${sessions[*]}"
}

# Find background VMs that can be preempted (no active session)
find_preemptable() {
    local preemptable=()

    while IFS= read -r vm_id; do
        [[ -z "$vm_id" ]] && continue

        # Check if VM has an active Sunshine session
        if ! has_active_session "$vm_id"; then
            preemptable+=("$vm_id")
        else
            log "VM $vm_id has active session, skipping for preemption"
        fi
    done < <(jq -r '.allocations | to_entries[] | select(.value.priority == "background") | .key' "$ALLOCATIONS_FILE" 2>/dev/null)

    echo "${preemptable[*]}"
}

# Request GPU allocation
request_gpu() {
    local vm_id="$1"
    local profile="${2:-Q-8C}"
    local priority="${3:-game}"

    acquire_lock
    init_state

    # Validate profile
    if [[ -z "${PROFILE_VRAM[$profile]}" ]]; then
        error "Unknown profile: $profile. Available: ${!PROFILE_VRAM[*]}"
    fi

    local required=${PROFILE_VRAM[$profile]}
    local available=$(get_available_vram)

    log "Request: VM $vm_id, profile $profile (${required}MB), available ${available}MB"

    # Check if already allocated
    if jq -e --arg vm_id "$vm_id" '.allocations[$vm_id]' "$ALLOCATIONS_FILE" > /dev/null 2>&1; then
        log "VM $vm_id already has GPU allocated"
        echo '{"status": "already_allocated", "vm_id": "'$vm_id'"}'
        return 0
    fi

    # Check if profile fits
    if profile_fits "$profile"; then
        add_allocation "$vm_id" "$profile" "$priority"
        log "Allocated $profile to VM $vm_id"
        echo '{"status": "allocated", "vm_id": "'$vm_id'", "profile": "'$profile'"}'
        return 0
    fi

    # Not enough VRAM - check for preemptable workloads
    if [[ "$priority" == "game" ]]; then
        local preemptable=$(find_preemptable)
        if [[ -n "$preemptable" ]]; then
            log "Insufficient VRAM. Preemptable background VMs: $preemptable"
            echo '{"status": "preempt_available", "vm_id": "'$vm_id'", "preemptable": ['$(echo "$preemptable" | jq -R . | paste -sd,)']}'
            return 1
        fi
    fi

    # Cannot allocate
    log "Cannot allocate $profile to VM $vm_id: need ${required}MB, have ${available}MB"
    echo '{"status": "insufficient_resources", "vm_id": "'$vm_id'", "required": '$required', "available": '$available'}'
    return 1
}

# Release GPU allocation
release_gpu() {
    local vm_id="$1"

    acquire_lock
    init_state

    if ! jq -e --arg vm_id "$vm_id" '.allocations[$vm_id]' "$ALLOCATIONS_FILE" > /dev/null 2>&1; then
        log "VM $vm_id has no GPU allocation"
        echo '{"status": "not_allocated", "vm_id": "'$vm_id'"}'
        return 0
    fi

    local profile=$(jq -r --arg vm_id "$vm_id" '.allocations[$vm_id].profile' "$ALLOCATIONS_FILE")
    remove_allocation "$vm_id"
    log "Released $profile from VM $vm_id"
    echo '{"status": "released", "vm_id": "'$vm_id'", "profile": "'$profile'"}'
}

# Check profile availability
check_profile() {
    local profile="$1"

    init_state

    if [[ -z "${PROFILE_VRAM[$profile]}" ]]; then
        error "Unknown profile: $profile"
    fi

    local required=${PROFILE_VRAM[$profile]}
    local available=$(get_available_vram)

    if profile_fits "$profile"; then
        echo '{"available": true, "profile": "'$profile'", "required": '$required', "free": '$available'}'
    else
        echo '{"available": false, "profile": "'$profile'", "required": '$required', "free": '$available'}'
    fi
}

# Show status
show_status() {
    init_state

    local used=$(get_used_vram)
    local available=$(get_available_vram)
    local active_sessions=$(get_active_sessions)

    echo "{"
    echo '  "total_vram": '$NVIDIA_TOTAL_VRAM','
    echo '  "used_vram": '$used','
    echo '  "available_vram": '$available','
    echo '  "active_sessions": ["'$(echo "$active_sessions" | sed 's/ /", "/g')'"],'
    echo '  "allocations": '$(get_allocations)
    echo "}"
}

# Main
case "${1:-}" in
    request)
        [[ -z "$2" ]] && error "Usage: $0 request <vm_id> [profile] [priority]"
        request_gpu "$2" "${3:-Q-8C}" "${4:-game}"
        ;;
    release)
        [[ -z "$2" ]] && error "Usage: $0 release <vm_id>"
        release_gpu "$2"
        ;;
    check)
        [[ -z "$2" ]] && error "Usage: $0 check <profile>"
        check_profile "$2"
        ;;
    status)
        show_status
        ;;
    sessions)
        echo "Active Sunshine sessions:"
        get_active_sessions | tr ' ' '\n'
        ;;
    *)
        echo "GPU Allocation Manager"
        echo ""
        echo "Usage:"
        echo "  $0 request <vm_id> [profile] [priority]  - Request GPU allocation"
        echo "  $0 release <vm_id>                       - Release GPU allocation"
        echo "  $0 check <profile>                       - Check profile availability"
        echo "  $0 status                                - Show current allocations and sessions"
        echo "  $0 sessions                              - List active Sunshine sessions"
        echo ""
        echo "Profiles: ${!PROFILE_VRAM[*]}"
        echo "Priorities: game, background"
        exit 1
        ;;
esac
