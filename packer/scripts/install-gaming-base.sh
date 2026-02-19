#!/bin/bash
# Install base gaming packages for Debian
set -ex

# Enable non-free repos for firmware
sudo sed -i 's/main$/main contrib non-free non-free-firmware/' /etc/apt/sources.list
sudo apt-get update

# Install desktop environment
sudo apt-get install -y \
    xorg \
    xfce4 \
    xfce4-goodies \
    lightdm \
    dbus-x11

# Install audio
sudo apt-get install -y \
    pulseaudio \
    pavucontrol \
    alsa-utils

# Install graphics utilities
sudo apt-get install -y \
    mesa-utils \
    vainfo \
    intel-media-va-driver \
    libva2 \
    libva-drm2 \
    libva-x11-2

# Install gaming utilities
sudo apt-get install -y \
    gamemode \
    mangohud

# Install NFS client
sudo apt-get install -y nfs-common

# Install Flatpak
sudo apt-get install -y flatpak
sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# Install useful tools
sudo apt-get install -y \
    curl \
    wget \
    git \
    jq \
    htop \
    neofetch \
    unzip \
    p7zip-full

# Create gaming user
sudo useradd -m -s /bin/bash -G audio,video,input,render gamer || true
echo "gamer:gamer" | sudo chpasswd

# Enable auto-login for gamer user (will be configured by Ansible)
sudo mkdir -p /etc/lightdm/lightdm.conf.d

echo "Gaming base installation complete"
