# GPU Driver Acquisition Guide

This document explains how to obtain and install GPU drivers for the cloud gaming infrastructure.

## NVIDIA vGPU Drivers (RTX A5000)

### Understanding vGPU Licensing

NVIDIA vGPU requires:
1. **vGPU-capable GPU** - Quadro/RTX professional cards (A5000, A6000, etc.) or data center GPUs
2. **vGPU Software** - Host and guest drivers from NVIDIA
3. **License Server** - Either NVIDIA's cloud licensing or self-hosted (FastAPI-DLS)

### Option 1: NVIDIA Licensing Portal (Official)

If you have an NVIDIA Enterprise account:

1. Log in to [NVIDIA Licensing Portal](https://nvid.nvidia.com/)
2. Navigate to **Software Downloads**
3. Download the **vGPU Software** bundle for your driver branch (e.g., 17.x, 16.x)
4. Extract the bundle - it contains:
   - `Host_Drivers/` - For Proxmox host
   - `Guest_Drivers/` - For Windows/Linux VMs

### Option 2: NVIDIA Eval License

For evaluation purposes:
1. Request an evaluation at [NVIDIA vGPU Evaluation](https://www.nvidia.com/en-us/data-center/resources/vgpu-evaluation/)
2. You'll get temporary access to the licensing portal
3. Download drivers as above

### Option 3: Community Sources (Use at Own Risk)

Some community members share drivers. This is against NVIDIA's EULA but commonly done for homelab use:

```bash
# The drivers role expects drivers in a specific location
# You can manually download and place them:
mkdir -p /opt/nvidia-vgpu-drivers
# Place NVIDIA-Linux-x86_64-XXX.XX.XX-grid.run here (host driver)
# Place NVIDIA-Linux-x86_64-XXX.XX.XX-grid-vgpu-kvm.run here (guest driver)
```

### Installing Host Drivers

Once you have the drivers:

```bash
# On Proxmox host
chmod +x NVIDIA-Linux-x86_64-*-grid.run

# Install with DKMS for kernel update resilience
./NVIDIA-Linux-x86_64-*-grid.run --dkms

# Verify installation
nvidia-smi
```

### FastAPI-DLS (Self-Hosted Licensing)

Instead of NVIDIA's cloud licensing, use FastAPI-DLS:

```yaml
# Already configured in ansible/roles/docker/templates/fastapi-dls.yaml.j2
# Deploy to your DLS server LXC:
ansible-playbook -l dls-server site.yml
```

Configure VMs to use it by setting `dls_server_ip` in your Ansible vars.

### Guest Driver Installation

**Automatic Distribution:**
Guest drivers are automatically synced from the Proxmox host to NAS:
```
Host downloads vGPU bundle → Ansible extracts guest drivers → NFS share
                                                              ↓
                              VMs mount /mnt/drivers/nvidia/{linux,windows}/
```

**Linux VMs:**
The Ansible gaming role handles this automatically:
1. Mounts NFS driver share: `/mnt/drivers/nvidia/linux/`
2. Finds the matching guest driver
3. Installs via DKMS
4. Configures licensing client (FastAPI-DLS)
5. Sets up virtual display via xorg.conf

You can also use cloud-init for first-boot installation (see `cloud-init-gaming.yaml.j2`).

**Windows VMs:**
Option 1: Ansible (preferred)
```bash
ansible-playbook -l windows-gaming site.yml -t gaming
```

Option 2: Manual
1. Map NFS share: `\\nas\tank\gaming\drivers\nvidia\windows\`
2. Run installer: `*-grid-win*.exe -s`
3. Reboot
4. Configure licensing in NVIDIA Control Panel → Manage License

## Intel SR-IOV Drivers

Intel SR-IOV uses the in-kernel i915 driver - no proprietary drivers needed.

### Host Setup

Kernel parameters are set automatically by the drivers role:
```
intel_iommu=on i915.enable_guc=3 i915.max_vfs=7
```

### Guest Setup

Linux VMs use the standard i915 driver (included in kernel).

For Windows VMs, Intel provides graphics drivers that work with SR-IOV VFs:
1. Download from [Intel Download Center](https://www.intel.com/content/www/us/en/download-center/home.html)
2. Search for your CPU's graphics (e.g., "Intel UHD Graphics 770")
3. Install the standard Windows driver

## Driver Version Matching

**Important:** vGPU host and guest driver versions should match.

The drivers role includes a script to check versions:
```bash
# On host
nvidia-smi --query-gpu=driver_version --format=csv,noheader

# The guest driver installation will try to match this version
```

## Troubleshooting

### Host driver won't install
```bash
# Check for nouveau
lsmod | grep nouveau
# If loaded, ensure blacklist is in place and reboot

# Check kernel headers
apt install pve-headers-$(uname -r)
```

### nvidia-smi shows no GPUs
```bash
# Check PCI device
lspci | grep -i nvidia

# Check driver loaded
lsmod | grep nvidia

# Check dmesg for errors
dmesg | grep -i nvidia
```

### vGPU mdev types not available
```bash
# After driver install, check mdev support
ls /sys/class/mdev_bus/*/mdev_supported_types/

# If empty, driver may not support vGPU on your card
# Verify card is vGPU-capable (professional/data center GPU)
```

### FastAPI-DLS licensing fails
```bash
# In VM, check licensing status
nvidia-smi -q | grep -i license

# Check DLS connectivity
curl -k https://dls-server:443/-/health

# Check gridd.conf
cat /etc/nvidia/gridd.conf
```
