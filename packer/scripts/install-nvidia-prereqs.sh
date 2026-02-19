#!/bin/bash
# Install NVIDIA vGPU guest driver prerequisites
# The actual driver is installed by Ansible based on the host's driver version
set -ex

# Install build tools for DKMS
sudo apt-get install -y \
    build-essential \
    dkms \
    linux-headers-$(uname -r) \
    pkg-config \
    libglvnd-dev

# Install NVIDIA container toolkit prerequisites
sudo apt-get install -y \
    libnvidia-container-tools \
    nvidia-container-toolkit || true

# Create NVIDIA config directory
sudo mkdir -p /etc/nvidia

# Create placeholder for gridd.conf (configured by Ansible)
sudo touch /etc/nvidia/gridd.conf

# Blacklist nouveau (in case it's not already)
sudo tee /etc/modprobe.d/blacklist-nouveau.conf > /dev/null << 'EOF'
blacklist nouveau
options nouveau modeset=0
EOF

# Note: initramfs will be updated when the actual driver is installed
echo "NVIDIA prerequisites installed"
echo "Note: vGPU guest driver will be installed by Ansible after VM deployment"
