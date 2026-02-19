# Gaming Infrastructure Configuration Example
# ===========================================
#
# Add this configuration to configurations.tfvars to enable gaming VMs.
# This file shows the additions needed for the cloud gaming setup.

# Add to existing hosts block:

hosts = {
  # ... existing proxmox config (NAS) ...

  # ==========================================================================
  # Workstation - NVIDIA RTX A5000 vGPU Gaming
  # ==========================================================================
  "workstation" = {
    ansible_user = "root"

    # Host-level roles for GPU setup
    roles = [
      {
        name = "drivers"
        vars = {
          gpu_type       = "nvidia_vgpu"
          dls_server_ip  = "192.168.1.100"  # FastAPI-DLS server
        }
      },
      { name = "gpu-manager" }
    ]

    # Gaming VMs with NVIDIA vGPU
    vms = {
      linux-gaming-1 = {
        memory       = 16384
        cores        = 8
        disk_size    = "64G"
        storage_pool = "games"  # ZFS RAID0 pool
        clone        = "debian-12-gaming"

        gpu_type     = "nvidia_vgpu"
        vgpu_profile = "Q-8C"

        sunshine_enabled  = true
        steam_enabled     = true
        snapshot_on_boot  = true

        roles = [
          {
            name = "gaming"
            vars = {
              nfs_server    = "192.168.1.100"
              dls_server_ip = "192.168.1.100"
            }
          }
        ]
      }

      linux-gaming-2 = {
        memory       = 16384
        cores        = 8
        disk_size    = "64G"
        storage_pool = "games"
        clone        = "debian-12-gaming"

        gpu_type     = "nvidia_vgpu"
        vgpu_profile = "Q-8C"

        sunshine_enabled  = true
        steam_enabled     = true
        snapshot_on_boot  = true

        roles = [
          {
            name = "gaming"
            vars = {
              nfs_server    = "192.168.1.100"
              dls_server_ip = "192.168.1.100"
            }
          }
        ]
      }

      windows-gaming = {
        memory       = 16384
        cores        = 8
        disk_size    = "128G"
        storage_pool = "games"
        clone        = "windows-11-gaming"

        gpu_type     = "nvidia_vgpu"
        vgpu_profile = "Q-8C"

        sunshine_enabled = true
        steam_enabled    = true

        # Windows-specific role (if created)
        # roles = [{ name = "gaming/windows" }]
      }
    }
  }

  # ==========================================================================
  # Intel Box - Intel iGPU SR-IOV for Emulation
  # ==========================================================================
  "intel-box" = {
    ansible_user = "root"

    # Host-level roles for SR-IOV setup
    roles = [
      {
        name = "drivers"
        vars = {
          gpu_type           = "intel_sriov"
          intel_sriov_num_vfs = 7
        }
      },
      { name = "gpu-manager" }
    ]

    vms = {
      emulation = {
        memory    = 8192
        cores     = 4
        disk_size = "32G"
        clone     = "debian-12-gaming"

        gpu_type         = "intel_sriov"
        sriov_vf_index   = 0  # VF0 for physical display
        physical_display = true

        sunshine_enabled  = true
        steam_enabled     = true
        retroarch_enabled = true
        snapshot_on_boot  = true

        roles = [
          {
            name = "gaming"
            vars = {
              nfs_server = "192.168.1.100"
            }
          }
        ]
      }
    }
  }
}

# ==========================================================================
# Additional Variables
# ==========================================================================

# Add these variables to your defaults.tf or pass them:

# variable "dls_server_ip" {
#   type        = string
#   description = "IP address of FastAPI-DLS server for vGPU licensing"
#   default     = "192.168.1.100"
# }

# variable "nfs_server" {
#   type        = string
#   description = "IP address of NAS for NFS game storage"
#   default     = "192.168.1.100"
# }

# ==========================================================================
# NAS Storage Configuration (add to proxmox host)
# ==========================================================================

# In the proxmox host's lxcs block, update the sharing container:
#
# sharing = {
#   mounts = [
#     {name = "cloudShare", dataset = "tank/cloud", path = "/storage/cloud"},
#     {name = "gaming", dataset = "tank/gaming", path = "/storage/gaming"}  # ADD THIS
#   ]
#   roles = [
#     { name = "network/sharing" }
#   ]
# }

# ==========================================================================
# ZFS Datasets to Create on NAS (manual or via additional role)
# ==========================================================================

# zfs create tank/gaming
# zfs create tank/gaming/emulation
# zfs create tank/gaming/emulation/roms
# zfs create tank/gaming/emulation/users
# zfs create tank/gaming/cloud-saves
# zfs create tank/gaming/sunshine-credentials

# ==========================================================================
# ZFS Pool on Workstation (2x NVMe RAID0)
# ==========================================================================

# zpool create -o ashift=12 games /dev/nvme0n1 /dev/nvme1n1
# zfs create games/vms
# zfs create games/steam
# zfs create games/gog
