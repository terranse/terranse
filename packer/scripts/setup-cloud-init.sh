#!/bin/bash
# Configure cloud-init for Proxmox NoCloud datasource
set -euxo pipefail

sudo mkdir -p /etc/cloud/cloud.cfg.d

# Restrict cloud-init to the NoCloud datasource so Proxmox's attached
# cloud-init drive is always picked up predictably on clones.
cat <<'EOF' | sudo tee /etc/cloud/cloud.cfg.d/99-proxmox.cfg
datasource_list: [NoCloud, None]
EOF

# Keep SSH password auth enabled on first boot — cloud-init's default on
# Ubuntu server is to disable it, which prevents fallback logins with the
# baked-in packer account. Also keep root usable so a first-time operator
# can always get in via noVNC console.
cat <<'EOF' | sudo tee /etc/cloud/cloud.cfg.d/99-ssh-pwauth.cfg
ssh_pwauth: true
disable_root: false
chpasswd:
  expire: false
EOF

sudo systemctl enable cloud-init
sudo systemctl enable qemu-guest-agent 2>/dev/null || true
