# Packer VM Templates

Automated VM template builds for Proxmox. Supports base (general-purpose) and gaming templates for Debian, Ubuntu, and Windows.

## Quick Start

```bash
# 1. Copy and fill in Proxmox credentials
cp packer/proxmox.pkrvars.hcl.example packer/proxmox.pkrvars.hcl
vi packer/proxmox.pkrvars.hcl

# 2. Update checksums in the OS catalog
vi packer/os-catalog.pkrvars.hcl

# 3. Build a template
just build-template debian 13 base
```

## Prerequisites

1. **Packer installed** on your local machine:
   ```bash
   # Debian/Ubuntu
   curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
   sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
   sudo apt-get update && sudo apt-get install packer
   ```

2. **Proxmox API token**:
   ```bash
   pveum user token add root@pam packer --privsep=0
   ```

3. **For Windows templates** — upload the Windows 11 ISO manually (cannot be auto-downloaded):
   ```bash
   just upload-iso ~/Downloads/Win11_24H2_English_x64.iso
   ```

## Architecture

```
packer/
  os-catalog.pkrvars.hcl        # OS lookup table (family/version → URL + checksum)
  proxmox.pkrvars.hcl           # Proxmox connection credentials (gitignored)
  proxmox.pkrvars.hcl.example   # Template for credentials
  http/
    preseed.cfg                 # Debian preseed (gaming)
    preseed-base.cfg            # Debian preseed (base)
    autoinstall/                # Ubuntu autoinstall
      user-data
      meta-data
  scripts/
    setup-cloud-init.sh         # Cloud-init Proxmox datasource setup
    install-gaming-base.sh      # Gaming: desktop + drivers
    install-steam.sh            # Gaming: Steam + Proton
    install-sunshine.sh         # Gaming: Sunshine streaming
    install-nvidia-prereqs.sh   # Gaming: NVIDIA prerequisites
  debian-base/                  # Debian base template
  ubuntu-base/                  # Ubuntu base template
  windows-base/                 # Windows base template
  debian-gaming/                # Debian gaming template
  windows-gaming/               # Windows gaming template
```

## OS Catalog

The catalog (`os-catalog.pkrvars.hcl`) maps OS family + version to ISO details. Linux ISOs are auto-downloaded by Packer; Windows ISOs must be pre-uploaded.

Adding a new OS version is just a URL + checksum:
```hcl
"debian-14" = {
  iso_url      = "https://cdimage.debian.org/debian-cd/..."
  iso_checksum = "sha256:abc123..."
  iso_file     = ""
  os_type      = "l26"
}
```

## Building Templates

### Using justfile (recommended)

```bash
# Base templates (auto-downloads ISO)
just build-template debian 13 base
just build-template ubuntu 2510 base
just build-template windows 11 base    # requires pre-uploaded ISO

# Gaming templates
just build-template debian 12 gaming
just build-template windows 11 gaming  # requires pre-uploaded ISO
```

### Manual build

```bash
cd packer/debian-base
packer init .
packer build \
  -var-file=../os-catalog.pkrvars.hcl \
  -var-file=../proxmox.pkrvars.hcl \
  -var "os_family=debian" \
  -var "os_version=13" \
  .
```

## Template Naming

Templates are identified by **name** — no fixed VM IDs for base templates (Proxmox auto-assigns). Gaming templates keep their legacy IDs (9000/9001) for backward compatibility.

| Template Name       | Purpose                     |
|---------------------|-----------------------------|
| debian-13-base      | General-purpose Debian 13   |
| ubuntu-2510-base    | General-purpose Ubuntu 25.10|
| windows-11-base     | General-purpose Windows 11  |
| debian-12-gaming    | Gaming Debian 12            |
| windows-11-gaming   | Gaming Windows 11           |

## Quick VM Testing (no tofu)

```bash
# Create a VM from a template
just create-vm test-loki debian-13-base

# SSH in (auto-injects local ed25519 key)
ssh packer@<vm-ip>

# List templates on Proxmox
just list-templates

# Clean up
just destroy-vm <vmid>
```

## What's Installed

### Base Templates

| Component       | Debian/Ubuntu             | Windows                 |
|-----------------|---------------------------|-------------------------|
| Cloud-init      | cloud-init (NoCloud)      | Cloudbase-Init          |
| Guest agent     | qemu-guest-agent          | QEMU guest agent        |
| Remote access   | SSH                       | RDP + WinRM             |
| Boot            | UEFI (OVMF/q35)          | UEFI (OVMF/q35) + TPM  |
| Packages        | curl, wget, git, vim, htop| -                       |

### Gaming Templates (extends base)

| Component | Debian                        | Windows                          |
|-----------|-------------------------------|----------------------------------|
| Desktop   | Xfce4 + LightDM              | -                                |
| Audio     | PulseAudio                    | -                                |
| Graphics  | Mesa, VA-API drivers          | -                                |
| Gaming    | Steam (Flatpak), Proton-GE, GameMode, MangoHud | Steam, Sunshine, DirectX, VCRedist |
| Streaming | Sunshine                      | Sunshine                         |
| NVIDIA    | Build prerequisites (driver via Ansible) | -                       |

## Post-Build

After building, templates are ready for cloning via `just create-vm` or via tofu.

Cloud-init handles networking and SSH keys on first boot. For gaming VMs, the Ansible gaming role handles NVIDIA driver installation, NFS mounts, and Sunshine configuration.

## Troubleshooting

### Build hangs at "Waiting for SSH"
1. Check Proxmox console for installer errors
2. Verify preseed/autoinstall is being served (check Packer HTTP server logs)
3. Ensure VM can reach the HTTP server on the Packer host

### ISO not found
```bash
# List available ISOs on Proxmox
just list-templates
ssh root@jupiter "pvesm list local --content iso"
```

### Checksum mismatch
Update the checksums in `os-catalog.pkrvars.hcl` — download the SHA256SUMS file from the distro's release page.

### Template creation fails
Ensure the API token has sufficient permissions:
```bash
pveum aclmod / -user root@pam -role Administrator
```
