terraform {
  required_providers {
    proxmox = {
      source  = "registry.terraform.io/telmate/proxmox"
      version = "3.0.2-rc07"
    }
  }
}

locals {
  # Generate VMID starting from 200 for gaming VMs
  vm_list = keys(var.configuration)
  vmid_map = {
    for idx, name in local.vm_list : name => 200 + idx
  }
}

# =============================================================================
# Gaming VMs with GPU passthrough
# =============================================================================
resource "proxmox_vm_qemu" "gaming_vms" {
  for_each = var.configuration

  target_node = var.host
  vmid        = local.vmid_map[each.key]
  name        = each.key
  desc        = "Gaming VM - ${each.value.gpu_type}"

  # VM Settings
  agent    = 1
  os_type  = "cloud-init"
  clone    = each.value.clone
  cores    = each.value.cores
  sockets  = 1
  cpu      = "host"
  memory   = each.value.memory
  scsihw   = "virtio-scsi-pci"
  bootdisk = "scsi0"
  onboot   = true

  # Primary disk (system)
  disk {
    slot     = 0
    size     = each.value.disk_size
    type     = "scsi"
    storage  = each.value.storage_pool
    iothread = 1
    cache    = "writeback"
    ssd      = 1
  }

  # Network
  network {
    model  = "virtio"
    bridge = "vmbr0"
  }

  # NVIDIA vGPU passthrough
  dynamic "hostpci" {
    for_each = each.value.gpu_type == "nvidia_vgpu" ? [1] : []
    content {
      host   = each.value.nvidia_pci
      mdev   = lookup(var.vgpu_mdev_types, each.value.vgpu_profile, "nvidia-259")
      rombar = 0
    }
  }

  # Intel SR-IOV VF passthrough
  dynamic "hostpci" {
    for_each = each.value.gpu_type == "intel_sriov" ? [1] : []
    content {
      host = "0000:00:02.${each.value.sriov_vf_index + 1}"
      pcie = true
    }
  }

  # Cloud-init configuration
  ciuser  = "gamer"
  sshkeys = var.ssh_key

  # UEFI boot for better compatibility
  bios = "ovmf"

  lifecycle {
    ignore_changes = [
      network,
      disk,
    ]
  }

  # Tags for identification
  tags = join(",", compact([
    "gaming",
    each.value.gpu_type,
    each.value.vgpu_profile != null ? each.value.vgpu_profile : "",
    each.value.retroarch_enabled ? "emulation" : "",
  ]))
}

# =============================================================================
# Outputs
# =============================================================================
output "gaming_vms" {
  value = {
    for name, vm in proxmox_vm_qemu.gaming_vms : name => {
      vmid     = vm.vmid
      name     = vm.name
      gpu_type = var.configuration[name].gpu_type
    }
  }
  description = "Map of created gaming VMs"
}

output "vm_ids" {
  value       = { for name, vm in proxmox_vm_qemu.gaming_vms : name => vm.vmid }
  description = "Map of VM names to VMIDs"
}
