#!/bin/bash
# Install Steam and dependencies
set -ex

# Enable i386 architecture
sudo dpkg --add-architecture i386
sudo apt-get update

# Install 32-bit libraries for Steam
sudo apt-get install -y \
    libgl1-mesa-dri:i386 \
    libgl1:i386 \
    libc6:i386 \
    libx11-6:i386 \
    libxext6:i386 \
    libxrender1:i386 \
    libxtst6:i386 \
    libxi6:i386

# Install Steam via Flatpak (more reliable than deb)
sudo flatpak install -y flathub com.valvesoftware.Steam

# Create Steam library directory structure
sudo mkdir -p /home/gamer/.steam/root/compatibilitytools.d
sudo chown -R gamer:gamer /home/gamer/.steam

# Download latest Proton-GE
PROTON_GE_VERSION=$(curl -s https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest | jq -r '.tag_name')
PROTON_GE_URL=$(curl -s https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest | jq -r '.assets[] | select(.name | endswith(".tar.gz")) | .browser_download_url')

if [[ -n "$PROTON_GE_URL" ]]; then
    echo "Downloading Proton-GE ${PROTON_GE_VERSION}..."
    curl -L -o /tmp/proton-ge.tar.gz "$PROTON_GE_URL"
    sudo tar -xzf /tmp/proton-ge.tar.gz -C /home/gamer/.steam/root/compatibilitytools.d/
    sudo chown -R gamer:gamer /home/gamer/.steam/root/compatibilitytools.d/
    rm -f /tmp/proton-ge.tar.gz
    echo "Proton-GE ${PROTON_GE_VERSION} installed"
else
    echo "Warning: Could not download Proton-GE"
fi

echo "Steam installation complete"
