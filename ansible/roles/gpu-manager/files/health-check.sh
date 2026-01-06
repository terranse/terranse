#!/bin/bash
# Health Check Script for Gaming Infrastructure
#
# Verifies that all gaming services are running correctly.
# Can be run standalone or integrated into Ansible playbooks.
#
# Usage:
#   health-check.sh [--json] [--quiet] [component...]
#
# Components: gpu, nfs, sunshine, session-watcher, all (default)
#
# Exit codes:
#   0 - All checks passed
#   1 - One or more checks failed
#   2 - Invalid arguments

set -euo pipefail

# Configuration
NFS_MOUNT="/mnt/gaming"
SESSION_STATE_DIR="${NFS_MOUNT}/session-state"
ALLOCATIONS_FILE="/var/lib/gpu-manager/allocations.json"

# Output format
JSON_OUTPUT=false
QUIET=false

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Parse arguments
COMPONENTS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        --quiet|-q)
            QUIET=true
            shift
            ;;
        *)
            COMPONENTS+=("$1")
            shift
            ;;
    esac
done

# Default to all components
[[ ${#COMPONENTS[@]} -eq 0 ]] && COMPONENTS=("all")

# Results tracking
declare -A RESULTS
FAILED=0

log() {
    if ! $QUIET; then
        echo -e "$1"
    fi
}

check_pass() {
    local name="$1"
    local msg="${2:-OK}"
    RESULTS["$name"]="pass"
    log "${GREEN}✓${NC} $name: $msg"
}

check_fail() {
    local name="$1"
    local msg="${2:-FAILED}"
    RESULTS["$name"]="fail"
    FAILED=$((FAILED + 1))
    log "${RED}✗${NC} $name: $msg"
}

check_warn() {
    local name="$1"
    local msg="${2:-WARNING}"
    RESULTS["$name"]="warn"
    log "${YELLOW}!${NC} $name: $msg"
}

# =============================================================================
# GPU Checks
# =============================================================================
check_gpu() {
    log "\n=== GPU Health Checks ==="

    # Check for NVIDIA driver
    if command -v nvidia-smi &>/dev/null; then
        if nvidia-smi &>/dev/null; then
            local gpu_info=$(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null | head -1)
            check_pass "nvidia-driver" "Loaded - $gpu_info"
        else
            check_fail "nvidia-driver" "Driver loaded but nvidia-smi failed"
        fi

        # Check mdev availability (vGPU)
        if [[ -d /sys/class/mdev_bus ]]; then
            local mdev_count=$(find /sys/class/mdev_bus -name 'mdev_supported_types' 2>/dev/null | wc -l)
            if [[ $mdev_count -gt 0 ]]; then
                check_pass "nvidia-vgpu" "mdev available ($mdev_count devices)"
            else
                check_warn "nvidia-vgpu" "mdev_bus exists but no supported types found"
            fi
        else
            check_warn "nvidia-vgpu" "mdev not available (may need vGPU driver)"
        fi
    else
        # Check for Intel GPU
        if [[ -d /sys/class/drm/card0 ]]; then
            local driver=$(cat /sys/class/drm/card0/device/driver/module/drivers/* 2>/dev/null | head -1 || echo "unknown")
            check_pass "intel-gpu" "GPU present"

            # Check SR-IOV
            local sriov_totalvfs=$(cat /sys/class/drm/card0/device/sriov_totalvfs 2>/dev/null || echo "0")
            if [[ "$sriov_totalvfs" -gt 0 ]]; then
                local sriov_numvfs=$(cat /sys/class/drm/card0/device/sriov_numvfs 2>/dev/null || echo "0")
                check_pass "intel-sriov" "SR-IOV enabled ($sriov_numvfs/$sriov_totalvfs VFs)"
            else
                check_warn "intel-sriov" "SR-IOV not available"
            fi
        else
            check_fail "gpu" "No GPU detected"
        fi
    fi

    # Check GPU manager state
    if [[ -f "$ALLOCATIONS_FILE" ]]; then
        local alloc_count=$(jq -r '.allocations | length' "$ALLOCATIONS_FILE" 2>/dev/null || echo "error")
        if [[ "$alloc_count" != "error" ]]; then
            check_pass "gpu-manager-state" "$alloc_count active allocations"
        else
            check_fail "gpu-manager-state" "Invalid allocations.json"
        fi
    else
        check_warn "gpu-manager-state" "No allocations file (first run?)"
    fi
}

# =============================================================================
# NFS Checks
# =============================================================================
check_nfs() {
    log "\n=== NFS Health Checks ==="

    # Check if NFS mount exists
    if mountpoint -q "$NFS_MOUNT" 2>/dev/null; then
        check_pass "nfs-mount" "Mounted at $NFS_MOUNT"

        # Check read access
        if [[ -r "${NFS_MOUNT}/drivers" ]]; then
            check_pass "nfs-read" "Read access OK"
        else
            check_fail "nfs-read" "Cannot read from NFS mount"
        fi

        # Check session state directory
        if [[ -d "$SESSION_STATE_DIR" ]]; then
            if [[ -w "$SESSION_STATE_DIR" ]]; then
                check_pass "nfs-session-state" "Session state directory writable"
            else
                check_fail "nfs-session-state" "Session state directory not writable"
            fi
        else
            check_warn "nfs-session-state" "Session state directory missing"
        fi

        # Check NFS responsiveness (timeout after 5s)
        if timeout 5 ls "$NFS_MOUNT" &>/dev/null; then
            check_pass "nfs-responsive" "NFS responding within 5s"
        else
            check_fail "nfs-responsive" "NFS not responding (timeout)"
        fi
    else
        check_fail "nfs-mount" "Not mounted at $NFS_MOUNT"
    fi
}

# =============================================================================
# Sunshine Checks
# =============================================================================
check_sunshine() {
    log "\n=== Sunshine Health Checks ==="

    # Check if Sunshine service is running
    if systemctl is-active --quiet sunshine 2>/dev/null; then
        check_pass "sunshine-service" "Service running"
    elif systemctl is-active --quiet sunshine --user 2>/dev/null; then
        check_pass "sunshine-service" "User service running"
    else
        check_fail "sunshine-service" "Service not running"
    fi

    # Check if Sunshine port is open
    if command -v ss &>/dev/null; then
        if ss -tlnp | grep -q ':47990\|:47984'; then
            check_pass "sunshine-port" "Listening on expected ports"
        else
            check_warn "sunshine-port" "Not listening on expected ports"
        fi
    fi

    # Check Sunshine config
    local sunshine_conf="/etc/sunshine/sunshine.conf"
    if [[ -f "$sunshine_conf" ]]; then
        check_pass "sunshine-config" "Config file exists"

        # Verify KMS capture is configured
        if grep -q "capture = kms" "$sunshine_conf" 2>/dev/null; then
            check_pass "sunshine-capture" "KMS capture configured"
        else
            check_warn "sunshine-capture" "KMS capture not configured"
        fi
    else
        check_warn "sunshine-config" "Config file not found at $sunshine_conf"
    fi
}

# =============================================================================
# Session Watcher Checks
# =============================================================================
check_session_watcher() {
    log "\n=== Session Watcher Health Checks ==="

    # Check if session-watcher service is running
    if systemctl is-active --quiet session-watcher 2>/dev/null; then
        check_pass "session-watcher-service" "Service running"
    else
        check_fail "session-watcher-service" "Service not running"
    fi

    # Check for stale session files (older than 1 hour with active status)
    if [[ -d "$SESSION_STATE_DIR" ]]; then
        local stale_count=0
        for session_file in "${SESSION_STATE_DIR}"/*.session; do
            [[ -f "$session_file" ]] || continue

            local status=$(jq -r '.status // empty' "$session_file" 2>/dev/null)
            if [[ "$status" == "active" ]]; then
                # Check if file is older than 1 hour
                local file_age=$(($(date +%s) - $(stat -c %Y "$session_file")))
                if [[ $file_age -gt 3600 ]]; then
                    stale_count=$((stale_count + 1))
                fi
            fi
        done

        if [[ $stale_count -gt 0 ]]; then
            check_warn "session-files" "$stale_count stale session files (>1 hour old)"
        else
            check_pass "session-files" "No stale session files"
        fi
    fi
}

# =============================================================================
# Output Results
# =============================================================================
output_results() {
    if $JSON_OUTPUT; then
        echo "{"
        echo '  "timestamp": "'$(date -Iseconds)'",'
        echo '  "hostname": "'$(hostname)'",'
        echo '  "failed_count": '$FAILED','
        echo '  "checks": {'
        local first=true
        for key in "${!RESULTS[@]}"; do
            if $first; then
                first=false
            else
                echo ","
            fi
            echo -n "    \"$key\": \"${RESULTS[$key]}\""
        done
        echo ""
        echo "  }"
        echo "}"
    else
        log "\n=== Summary ==="
        if [[ $FAILED -eq 0 ]]; then
            log "${GREEN}All checks passed${NC}"
        else
            log "${RED}$FAILED check(s) failed${NC}"
        fi
    fi
}

# =============================================================================
# Main
# =============================================================================
main() {
    for component in "${COMPONENTS[@]}"; do
        case "$component" in
            gpu)
                check_gpu
                ;;
            nfs)
                check_nfs
                ;;
            sunshine)
                check_sunshine
                ;;
            session-watcher)
                check_session_watcher
                ;;
            all)
                check_gpu
                check_nfs
                check_sunshine
                check_session_watcher
                ;;
            *)
                echo "Unknown component: $component" >&2
                echo "Valid components: gpu, nfs, sunshine, session-watcher, all" >&2
                exit 2
                ;;
        esac
    done

    output_results

    exit $FAILED
}

main
