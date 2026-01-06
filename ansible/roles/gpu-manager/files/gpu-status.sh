#!/bin/bash
# GPU Status Script
#
# Shows current GPU allocation status for NVIDIA vGPU and Intel SR-IOV

set -e

STATE_DIR="/var/lib/gpu-manager"
ALLOCATIONS_FILE="${STATE_DIR}/allocations.json"

# NVIDIA configuration
NVIDIA_TOTAL_VRAM=24576  # MB

# Profile VRAM requirements (MB)
declare -A PROFILE_VRAM=(
    ["Q-1C"]=1024
    ["Q-2C"]=2048
    ["Q-4C"]=4096
    ["Q-8C"]=8192
    ["Q-12C"]=12288
    ["Q-24C"]=24576
)

# Calculate used VRAM
get_used_vram() {
    local total=0
    if [[ -f "$ALLOCATIONS_FILE" ]]; then
        for profile in $(jq -r '.allocations | to_entries[] | .value.profile' "$ALLOCATIONS_FILE" 2>/dev/null); do
            total=$((total + ${PROFILE_VRAM[$profile]:-0}))
        done
    fi
    echo $total
}

# Print header
echo "========================================"
echo "        GPU Allocation Status"
echo "========================================"
echo ""

# NVIDIA vGPU Status
echo "NVIDIA vGPU (RTX A5000):"
echo "------------------------"

if command -v nvidia-smi &> /dev/null; then
    echo "Driver loaded: Yes"
    nvidia-smi --query-gpu=name,memory.total,memory.used --format=csv,noheader 2>/dev/null || echo "  (nvidia-smi query failed)"
else
    echo "Driver loaded: No (nvidia-smi not found)"
fi

# Check mdev types
if [[ -d /sys/class/mdev_bus ]]; then
    echo ""
    echo "Available mdev types:"
    find /sys/class/mdev_bus -name "available_instances" -exec sh -c 'echo "  $(dirname {} | xargs basename): $(cat {})"' \; 2>/dev/null | head -10
fi

echo ""

# Allocation state
echo "Current Allocations:"
echo "--------------------"

if [[ -f "$ALLOCATIONS_FILE" ]]; then
    used=$(get_used_vram)
    available=$((NVIDIA_TOTAL_VRAM - used))

    echo "Total VRAM:     ${NVIDIA_TOTAL_VRAM} MB"
    echo "Used VRAM:      ${used} MB"
    echo "Available VRAM: ${available} MB"
    echo ""

    allocation_count=$(jq -r '.allocations | length' "$ALLOCATIONS_FILE")

    if [[ "$allocation_count" -gt 0 ]]; then
        echo "Active allocations:"
        jq -r '.allocations | to_entries[] | "  VM \(.key): \(.value.profile) (\(.value.priority)) - allocated \(.value.allocated_at)"' "$ALLOCATIONS_FILE"
    else
        echo "No active allocations"
    fi
else
    echo "No allocation state file found"
fi

echo ""

# Intel SR-IOV Status
echo "Intel SR-IOV:"
echo "-------------"

if [[ -f /sys/devices/pci0000:00/0000:00:02.0/sriov_numvfs ]]; then
    num_vfs=$(cat /sys/devices/pci0000:00/0000:00:02.0/sriov_numvfs)
    total_vfs=$(cat /sys/devices/pci0000:00/0000:00:02.0/sriov_totalvfs 2>/dev/null || echo "?")
    echo "SR-IOV enabled: Yes"
    echo "Active VFs: ${num_vfs}/${total_vfs}"

    if [[ "$num_vfs" -gt 0 ]]; then
        echo ""
        echo "Virtual Functions:"
        ls -la /sys/devices/pci0000:00/0000:00:02.0/ 2>/dev/null | grep virtfn | while read line; do
            vf=$(echo "$line" | awk '{print $NF}')
            echo "  $vf"
        done
    fi
else
    echo "SR-IOV enabled: No"
fi

echo ""
echo "========================================"
