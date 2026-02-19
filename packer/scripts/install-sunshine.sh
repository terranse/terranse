#!/bin/bash
# Install Sunshine streaming server
set -ex

# Install dependencies
sudo apt-get install -y \
    libavcodec-dev \
    libdrm-dev \
    libevdev-dev \
    libpulse-dev \
    libx11-dev \
    libxfixes-dev \
    libxrandr-dev \
    libxtst-dev \
    libcap2-bin \
    libssl-dev \
    libcurl4-openssl-dev \
    libopus-dev \
    libboost-all-dev

# Get latest Sunshine release
SUNSHINE_VERSION=$(curl -s https://api.github.com/repos/LizardByte/Sunshine/releases/latest | jq -r '.tag_name')
SUNSHINE_DEB_URL=$(curl -s https://api.github.com/repos/LizardByte/Sunshine/releases/latest | jq -r '.assets[] | select(.name | contains("debian") and contains("amd64") and endswith(".deb")) | .browser_download_url' | head -1)

if [[ -n "$SUNSHINE_DEB_URL" ]]; then
    echo "Downloading Sunshine ${SUNSHINE_VERSION}..."
    curl -L -o /tmp/sunshine.deb "$SUNSHINE_DEB_URL"
    sudo apt-get install -y /tmp/sunshine.deb
    rm -f /tmp/sunshine.deb
    echo "Sunshine ${SUNSHINE_VERSION} installed"
else
    echo "Warning: Could not find Sunshine deb package, trying bookworm..."
    # Fallback to specific version
    curl -L -o /tmp/sunshine.deb "https://github.com/LizardByte/Sunshine/releases/download/v0.23.1/sunshine-debian-bookworm-amd64.deb"
    sudo apt-get install -y /tmp/sunshine.deb || true
    rm -f /tmp/sunshine.deb
fi

# Set capabilities
sudo setcap cap_sys_admin+ep /usr/bin/sunshine 2>/dev/null || true

# Create Sunshine config directory
sudo mkdir -p /home/gamer/.config/sunshine
sudo chown -R gamer:gamer /home/gamer/.config

# Create systemd service for Sunshine (runs as gamer user)
sudo tee /etc/systemd/system/sunshine.service > /dev/null << 'EOF'
[Unit]
Description=Sunshine Game Streaming Server
After=network.target display-manager.service
Wants=display-manager.service

[Service]
Type=simple
User=gamer
Group=gamer
ExecStart=/usr/bin/sunshine
Restart=on-failure
RestartSec=5
Environment=DISPLAY=:0
Environment=HOME=/home/gamer

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable sunshine

echo "Sunshine installation complete"
