#!/bin/bash
# Session Monitor for Gaming Infrastructure
#
# Monitors active Sunshine sessions and sends notifications via webhook.
# Integrates with Discord, Slack, or any webhook-compatible service.
#
# Usage:
#   session-monitor.sh [--daemon] [--webhook URL]
#
# Environment:
#   GAMING_WEBHOOK_URL - Webhook URL for notifications
#   GAMING_WEBHOOK_TYPE - webhook type: discord, slack, generic (default: generic)

set -euo pipefail

# Configuration
SESSION_STATE_DIR="/mnt/gaming/session-state"
MONITOR_STATE_FILE="/var/lib/gpu-manager/monitor-state.json"
POLL_INTERVAL="${POLL_INTERVAL:-30}"  # seconds
WEBHOOK_URL="${GAMING_WEBHOOK_URL:-}"
WEBHOOK_TYPE="${GAMING_WEBHOOK_TYPE:-generic}"

# State tracking
declare -A KNOWN_SESSIONS

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Load previous state
load_state() {
    if [[ -f "$MONITOR_STATE_FILE" ]]; then
        while IFS= read -r line; do
            local vm_id=$(echo "$line" | jq -r '.vm_id')
            local status=$(echo "$line" | jq -r '.status')
            KNOWN_SESSIONS["$vm_id"]="$status"
        done < <(jq -c '.sessions[]' "$MONITOR_STATE_FILE" 2>/dev/null || true)
    fi
}

# Save current state
save_state() {
    local sessions_json="["
    local first=true
    for vm_id in "${!KNOWN_SESSIONS[@]}"; do
        if $first; then
            first=false
        else
            sessions_json+=","
        fi
        sessions_json+="{\"vm_id\":\"$vm_id\",\"status\":\"${KNOWN_SESSIONS[$vm_id]}\"}"
    done
    sessions_json+="]"

    mkdir -p "$(dirname "$MONITOR_STATE_FILE")"
    echo "{\"sessions\":$sessions_json,\"last_check\":\"$(date -Iseconds)\"}" > "$MONITOR_STATE_FILE"
}

# Send notification via webhook
send_notification() {
    local title="$1"
    local message="$2"
    local color="${3:-}"

    [[ -z "$WEBHOOK_URL" ]] && return 0

    local payload
    case "$WEBHOOK_TYPE" in
        discord)
            # Discord webhook format
            local embed_color
            case "$color" in
                green) embed_color=5763719 ;;   # Green
                red) embed_color=15548997 ;;    # Red
                yellow) embed_color=16776960 ;; # Yellow
                *) embed_color=5793266 ;;       # Blue
            esac
            payload=$(cat <<EOF
{
    "embeds": [{
        "title": "$title",
        "description": "$message",
        "color": $embed_color,
        "timestamp": "$(date -Iseconds)"
    }]
}
EOF
            )
            ;;
        slack)
            # Slack webhook format
            payload=$(cat <<EOF
{
    "blocks": [
        {
            "type": "header",
            "text": {"type": "plain_text", "text": "$title"}
        },
        {
            "type": "section",
            "text": {"type": "mrkdwn", "text": "$message"}
        }
    ]
}
EOF
            )
            ;;
        *)
            # Generic webhook format
            payload=$(cat <<EOF
{
    "title": "$title",
    "message": "$message",
    "timestamp": "$(date -Iseconds)",
    "hostname": "$(hostname)"
}
EOF
            )
            ;;
    esac

    curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL" >/dev/null 2>&1 || \
        log "WARNING: Failed to send notification to webhook"
}

# Get session details from file
get_session_info() {
    local session_file="$1"
    local field="$2"
    jq -r ".$field // empty" "$session_file" 2>/dev/null
}

# Check for session changes
check_sessions() {
    local current_sessions=()

    # Scan session files
    for session_file in "${SESSION_STATE_DIR}"/*.session; do
        [[ -f "$session_file" ]] || continue

        local vm_id=$(get_session_info "$session_file" "vm_id")
        local status=$(get_session_info "$session_file" "status")
        local client_ip=$(get_session_info "$session_file" "client_ip")
        local started_at=$(get_session_info "$session_file" "started_at")
        local profile=$(get_session_info "$session_file" "gpu_profile")

        [[ -z "$vm_id" ]] && continue

        current_sessions+=("$vm_id")

        # Check for new or changed sessions
        local prev_status="${KNOWN_SESSIONS[$vm_id]:-}"

        if [[ -z "$prev_status" && "$status" == "active" ]]; then
            # New session started
            log "Session started: VM $vm_id (client: ${client_ip:-unknown}, profile: ${profile:-unknown})"
            send_notification \
                "Gaming Session Started" \
                "**VM:** $vm_id\n**Client:** ${client_ip:-unknown}\n**GPU Profile:** ${profile:-unknown}" \
                "green"

        elif [[ "$prev_status" == "active" && "$status" != "active" ]]; then
            # Session ended
            log "Session ended: VM $vm_id"
            send_notification \
                "Gaming Session Ended" \
                "**VM:** $vm_id\n**Duration:** since ${started_at:-unknown}" \
                "yellow"

        elif [[ "$prev_status" != "active" && "$status" == "active" ]]; then
            # Session resumed
            log "Session resumed: VM $vm_id"
            send_notification \
                "Gaming Session Resumed" \
                "**VM:** $vm_id" \
                "green"
        fi

        KNOWN_SESSIONS["$vm_id"]="$status"
    done

    # Check for removed sessions (files deleted)
    for vm_id in "${!KNOWN_SESSIONS[@]}"; do
        local found=false
        for current in "${current_sessions[@]}"; do
            [[ "$current" == "$vm_id" ]] && found=true && break
        done

        if ! $found && [[ "${KNOWN_SESSIONS[$vm_id]}" == "active" ]]; then
            log "Session disappeared: VM $vm_id (file removed)"
            send_notification \
                "Gaming Session Lost" \
                "**VM:** $vm_id\n**Reason:** Session file removed unexpectedly" \
                "red"
            unset "KNOWN_SESSIONS[$vm_id]"
        fi
    done
}

# Monitor GPU utilization
check_gpu_usage() {
    if command -v nvidia-smi &>/dev/null; then
        local gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1)
        local mem_util=$(nvidia-smi --query-gpu=utilization.memory --format=csv,noheader,nounits 2>/dev/null | head -1)

        # Warn if GPU is heavily loaded
        if [[ "${gpu_util:-0}" -gt 95 ]]; then
            log "WARNING: GPU utilization at ${gpu_util}%"
            send_notification \
                "High GPU Usage Alert" \
                "GPU utilization is at **${gpu_util}%**\nMemory utilization: ${mem_util:-unknown}%" \
                "yellow"
        fi
    fi
}

# Daemon mode
run_daemon() {
    log "Starting session monitor daemon (poll interval: ${POLL_INTERVAL}s)"

    load_state

    while true; do
        check_sessions
        check_gpu_usage
        save_state
        sleep "$POLL_INTERVAL"
    done
}

# Single check mode
run_once() {
    load_state
    check_sessions
    check_gpu_usage
    save_state
}

# Parse arguments
DAEMON_MODE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --daemon|-d)
            DAEMON_MODE=true
            shift
            ;;
        --webhook)
            WEBHOOK_URL="$2"
            shift 2
            ;;
        --type)
            WEBHOOK_TYPE="$2"
            shift 2
            ;;
        --interval)
            POLL_INTERVAL="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--daemon] [--webhook URL] [--type discord|slack|generic] [--interval SECONDS]" >&2
            exit 1
            ;;
    esac
done

# Main
if $DAEMON_MODE; then
    run_daemon
else
    run_once
fi
