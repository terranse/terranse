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

# First-boot DNS registration (one-off, via cloud-init's per-instance hook).
#
# OPNsense's dnsmasq registers <hostname>.<domain> from the DHCP lease's
# client-hostname (option 12). Only the FIRST boot races: systemd-networkd
# takes its initial lease before cloud-init sets the hostname, so that lease
# carries none and the VM never lands in DNS. On every later reboot the
# hostname is already in /etc/hostname and applied before networkd starts, so
# the lease carries it without help. cloud-init runs per-instance scripts once
# (first boot, after the hostname module), so a single DHCP renew there is all
# that's needed — no recurring service.
sudo mkdir -p /var/lib/cloud/scripts/per-instance
cat <<'EOF' | sudo tee /var/lib/cloud/scripts/per-instance/10-dhcp-register-hostname.sh
#!/bin/sh
# Re-request DHCP so the lease carries the now-set hostname for DNS registration.
set -e
for link in $(networkctl --no-legend list 2>/dev/null | awk '$3 == "ether" { print $2 }'); do
    networkctl renew "$link" 2>/dev/null || true
done
EOF
sudo chmod +x /var/lib/cloud/scripts/per-instance/10-dhcp-register-hostname.sh

sudo systemctl enable cloud-init
sudo systemctl enable qemu-guest-agent 2>/dev/null || true
