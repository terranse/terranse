#!/bin/bash
# Session Watcher - Runs on Proxmox host
#
# Watches the NFS-shared session state directory and controls VM lifecycle:
# - Resumes suspended VMs when Sunshine sessions start
# - Suspends VMs after sessions end (with grace period)
#
# This bridges the gap between Sunshine (running in VM) and Proxmox (host).
#
# Usage:
#   session-watcher.sh              # Run in foreground
#   session-watcher.sh --daemon     # Run as daemon
#
# Configuration:
#   SESSION_STATE_DIR: NFS mount with session files from VMs
#   SUSPEND_GRACE_PERIOD: Seconds to wait before suspending after session ends
#   VM_MAP_FILE: JSON mapping hostnames to VMIDs

set -e

# Configuration
SESSION_STATE_DIR="${SESSION_STATE_DIR:-/mnt/gaming/session-state}"
SUSPEND_GRACE_PERIOD="${SUSPEND_GRACE_PERIOD:-300}"  # 5 minutes
VM_MAP_FILE="${VM_MAP_FILE:-/etc/gpu-manager/vm-map.json}"
LOG_FILE="/var/log/session-watcher.log"
STATE_FILE="/var/lib/gpu-manager/watcher-state.json"

# Logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error() {
    log "ERROR: $1"
}

# Initialize state
init_state() {
    mkdir -p "$(dirname "$STATE_FILE")"
    if [[ ! -f "$STATE_FILE" ]]; then
        echo '{"pending_suspends": {}}' > "$STATE_FILE"
    fi
}

# Get VMID from hostname
get_vmid() {
    local hostname="$1"
    if [[ -f "$VM_MAP_FILE" ]]; then
        jq -r --arg host "$hostname" '.[$host] // empty' "$VM_MAP_FILE"
    fi
}

# Get VM status
get_vm_status() {
    local vmid="$1"
    qm status "$vmid" 2>/dev/null | awk '{print $2}'
}

# Resume a suspended VM
resume_vm() {
    local vmid="$1"
    local status=$(get_vm_status "$vmid")

    case "$status" in
        suspended)
            log "Resuming VM $vmid from suspended state"
            qm resume "$vmid"
            ;;
        stopped)
            log "Starting VM $vmid"
            qm start "$vmid"
            ;;
        running)
            log "VM $vmid already running"
            ;;
        *)
            error "Unknown VM status for $vmid: $status"
            ;;
    esac
}

# Suspend a VM
suspend_vm() {
    local vmid="$1"
    local status=$(get_vm_status "$vmid")

    if [[ "$status" == "running" ]]; then
        log "Suspending VM $vmid"
        qm suspend "$vmid" --todisk
    else
        log "VM $vmid not running (status: $status), skipping suspend"
    fi
}

# Cancel pending suspend for a VM
cancel_pending_suspend() {
    local vmid="$1"
    jq --arg vmid "$vmid" 'del(.pending_suspends[$vmid])' "$STATE_FILE" > "${STATE_FILE}.tmp"
    mv "${STATE_FILE}.tmp" "$STATE_FILE"
    log "Cancelled pending suspend for VM $vmid"
}

# Schedule a VM for suspend
schedule_suspend() {
    local vmid="$1"
    local suspend_at=$(($(date +%s) + SUSPEND_GRACE_PERIOD))

    jq --arg vmid "$vmid" --arg time "$suspend_at" \
       '.pending_suspends[$vmid] = ($time | tonumber)' "$STATE_FILE" > "${STATE_FILE}.tmp"
    mv "${STATE_FILE}.tmp" "$STATE_FILE"
    log "Scheduled VM $vmid for suspend at $(date -d "@$suspend_at" '+%H:%M:%S')"
}

# Process pending suspends
process_pending_suspends() {
    local now=$(date +%s)
    local pending=$(jq -r '.pending_suspends | to_entries[] | "\(.key) \(.value)"' "$STATE_FILE" 2>/dev/null)

    while IFS=' ' read -r vmid suspend_at; do
        [[ -z "$vmid" ]] && continue

        if [[ $now -ge $suspend_at ]]; then
            # Check if session became active again
            local hostname=$(jq -r --arg vmid "$vmid" 'to_entries[] | select(.value == ($vmid | tonumber)) | .key' "$VM_MAP_FILE" 2>/dev/null)
            local session_file="${SESSION_STATE_DIR}/${hostname}.session"

            if [[ -f "$session_file" ]]; then
                local status=$(jq -r '.status // empty' "$session_file" 2>/dev/null)
                if [[ "$status" == "active" ]]; then
                    log "Session became active again for VM $vmid, cancelling suspend"
                    cancel_pending_suspend "$vmid"
                    continue
                fi
            fi

            suspend_vm "$vmid"
            cancel_pending_suspend "$vmid"
        fi
    done <<< "$pending"
}

# Process a session file
process_session() {
    local session_file="$1"
    local hostname=$(basename "$session_file" .session)
    local vmid=$(get_vmid "$hostname")

    if [[ -z "$vmid" ]]; then
        log "No VMID mapping for hostname: $hostname"
        return
    fi

    local status=$(jq -r '.status // empty' "$session_file" 2>/dev/null)
    local session_start=$(jq -r '.session_start // empty' "$session_file" 2>/dev/null)

    case "$status" in
        active)
            log "Active session detected for $hostname (VM $vmid)"
            cancel_pending_suspend "$vmid" 2>/dev/null || true
            resume_vm "$vmid"
            ;;
        inactive)
            log "Session ended for $hostname (VM $vmid)"
            schedule_suspend "$vmid"
            ;;
    esac
}

# Watch for session changes using inotifywait
watch_sessions() {
    log "Starting session watcher on $SESSION_STATE_DIR"

    # Process existing sessions first
    for session_file in "${SESSION_STATE_DIR}"/*.session; do
        [[ -f "$session_file" ]] && process_session "$session_file"
    done

    # Watch for changes
    inotifywait -m -e modify -e create -e delete "$SESSION_STATE_DIR" 2>/dev/null | while read -r dir event file; do
        if [[ "$file" == *.session ]]; then
            log "Session change detected: $event $file"
            if [[ "$event" == "DELETE" ]]; then
                # Session file deleted - treat as session end
                local hostname=$(basename "$file" .session)
                local vmid=$(get_vmid "$hostname")
                [[ -n "$vmid" ]] && schedule_suspend "$vmid"
            else
                process_session "${SESSION_STATE_DIR}/${file}"
            fi
        fi
    done &

    # Periodic check for pending suspends
    while true; do
        process_pending_suspends
        sleep 30
    done
}

# Main
case "${1:-}" in
    --daemon)
        log "Starting session watcher daemon"
        init_state
        watch_sessions &
        echo $! > /var/run/session-watcher.pid
        wait
        ;;
    --process-once)
        # Process sessions once and exit (for cron/timer)
        init_state
        for session_file in "${SESSION_STATE_DIR}"/*.session; do
            [[ -f "$session_file" ]] && process_session "$session_file"
        done
        process_pending_suspends
        ;;
    *)
        init_state
        watch_sessions
        ;;
esac
