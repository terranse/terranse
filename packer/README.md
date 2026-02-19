# Packer Gaming VM Templates

Automated VM template builds for the cloud gaming infrastructure.

## Prerequisites

1. **Packer installed** on your local machine:
   ```bash
   # Debian/Ubuntu
   curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
   sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
   sudo apt-get update && sudo apt-get install packer
   ```

2. **Debian ISO** uploaded to Proxmox:
   ```bash
   # Download latest Debian 12 netinst
   wget https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12.8.0-amd64-netinst.iso

   # Upload to Proxmox (adjust node name as needed)
   scp debian-12.8.0-amd64-netinst.iso root@proxmox:/var/lib/vz/template/iso/
   ```

3. **Proxmox API token**:
   ```bash
   # On Proxmox, create API token
   pveum user token add root@pam packer --privsep=0
   ```

## Building Templates

### Debian Gaming Template

```bash
cd packer/debian-gaming

# Initialize Packer plugins
packer init .

# Build the template
packer build \
  -var "proxmox_url=https://proxmox.local:8006/api2/json" \
  -var "proxmox_username=root@pam!packer" \
  -var "proxmox_token=your-token-here" \
  -var "proxmox_node=workstation" \
  -var "vm_id=9000" \
  -var "iso_file=local:iso/debian-12.8.0-amd64-netinst.iso" \
  debian-gaming.pkr.hcl
```

### Using a Variables File

Create `variables.pkrvars.hcl`:
```hcl
proxmox_url      = "https://192.168.1.100:8006/api2/json"
proxmox_username = "root@pam!packer"
proxmox_token    = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
proxmox_node     = "workstation"
vm_id            = 9000
iso_file         = "local:iso/debian-12.8.0-amd64-netinst.iso"
```

Then build:
```bash
packer build -var-file=variables.pkrvars.hcl debian-gaming.pkr.hcl
```

## What's Installed

The Debian gaming template includes:

| Component | Details |
|-----------|---------|
| Desktop | Xfce4 + LightDM |
| Audio | PulseAudio |
| Graphics | Mesa, VA-API drivers |
| Gaming | Steam (Flatpak), Proton-GE, GameMode, MangoHud |
| Streaming | Sunshine (latest release) |
| NVIDIA | Build prerequisites (DKMS, headers) - driver installed by Ansible |
| User | `gamer` with auto-login configured |

## Post-Build Configuration

After building, the template is ready for cloning. When you create VMs from this template:

1. **Cloud-init** configures networking and SSH keys
2. **Ansible gaming role** installs:
   - Actual NVIDIA vGPU guest driver (matches host version)
   - NFS mounts for game storage
   - Sunshine configuration with GPU hooks
   - ZFS snapshot integration

### Windows Gaming Template

Windows requires additional ISOs:

1. **Windows 11 ISO** - Download from Microsoft
2. **VirtIO drivers ISO** - Download from [Fedora](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso)

```bash
# Upload ISOs to Proxmox
scp Win11_23H2_English_x64.iso root@proxmox:/var/lib/vz/template/iso/
scp virtio-win.iso root@proxmox:/var/lib/vz/template/iso/

# Build Windows template
cd packer/windows-gaming
packer init ../debian-gaming  # Uses same plugin
packer build \
  -var "proxmox_url=https://proxmox.local:8006/api2/json" \
  -var "proxmox_username=root@pam!packer" \
  -var "proxmox_token=your-token-here" \
  -var "proxmox_node=workstation" \
  -var "vm_id=9001" \
  -var "iso_file=local:iso/Win11_23H2_English_x64.iso" \
  -var "virtio_iso=local:iso/virtio-win.iso" \
  windows-gaming.pkr.hcl
```

**Note:** Windows builds take 30-60 minutes due to Windows Update and sysprep.

### Post-Build: NVIDIA Guest Drivers

NVIDIA vGPU guest drivers must be installed manually after cloning:
1. Copy guest driver to VM
2. Run installer
3. Configure licensing in NVIDIA Control Panel

See [GPU Drivers Guide](../docs/gpu-drivers.md) for details.

## Template IDs

Suggested template ID scheme:
- `9000` - Debian 12 Gaming (Linux)
- `9001` - Windows 11 Gaming
- `9002` - Debian 12 Emulation (lightweight)

## Troubleshooting

### Build hangs at "Waiting for SSH"

1. Check Proxmox console for installer errors
2. Verify preseed.cfg is being served (check Packer logs for HTTP server)
3. Ensure VM can reach the HTTP server on the Packer host

### ISO not found

Verify the ISO path format:
```bash
# List available ISOs on Proxmox
pvesm list local --content iso
```

### Template creation fails

Ensure the API token has sufficient permissions:
```bash
pveum aclmod / -user root@pam -role Administrator
```

## Customization

### Different Desktop Environment

Edit `scripts/install-gaming-base.sh` to replace Xfce with your preferred DE:
```bash
# KDE Plasma
sudo apt-get install -y kde-plasma-desktop sddm

# GNOME
sudo apt-get install -y gnome-core gdm3
```

### Smaller Template (Emulation Only)

For Intel Box emulation VMs, create a lighter template:
```bash
# Skip Steam in preseed, just install RetroArch
sudo flatpak install -y flathub org.libretro.RetroArch
```
