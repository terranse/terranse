terraform {
  required_providers {
    proxmox = {
      source  = "registry.terraform.io/telmate/proxmox"
      version = "3.0.2-rc07"
    }
  }
}

locals {
  vm_list = keys(var.configuration)
  vmid_map = {
    for idx, name in local.vm_list : name => 300 + idx
  }

  # Per-VM family flag: Windows templates still use SATA/e1000 (built-in
  # Windows drivers, no VirtIO injection needed during install), but now
  # boot via OVMF/UEFI — required for modern NVIDIA GPU passthrough with
  # Resizable BAR. Linux cloud images use OVMF + virtio-scsi + virtio-net.
  is_windows = {
    for name, vm in var.configuration :
    name => startswith(vm.clone, "windows-")
  }

  os_type = {
    for name, vm in var.configuration : name => coalesce(
      vm.os_type,
      local.is_windows[name] ? "win11" : "cloud-init"
    )
  }

  bios = {
    for name, vm in var.configuration : name => coalesce(
      vm.bios,
      "ovmf"
    )
  }

  disk_slot = {
    for name, vm in var.configuration : name => coalesce(
      vm.disk_slot,
      local.is_windows[name] ? "sata0" : "scsi0"
    )
  }

  network_model = {
    for name, vm in var.configuration : name => coalesce(
      vm.network_model,
      local.is_windows[name] ? "e1000" : "virtio"
    )
  }

  # Derive a stable MAC from the VM name when not explicitly set, so that
  # applies don't churn net0 and DHCP leases stay pinned.
  mac_address = {
    for name, vm in var.configuration : name => coalesce(
      vm.mac_address,
      format(
        "BC:24:11:%s:%s:%s",
        upper(substr(md5(name), 0, 2)),
        upper(substr(md5(name), 2, 2)),
        upper(substr(md5(name), 4, 2)),
      )
    )
  }
}

resource "proxmox_vm_qemu" "vms" {
  for_each = var.configuration

  target_node = var.proxmox_node != "" ? var.proxmox_node : var.host
  vmid        = try(each.value.vmid, local.vmid_map[each.key])
  name        = each.key

  agent      = 1
  os_type    = local.os_type[each.key]
  clone      = each.value.clone
  full_clone = each.value.full_clone
  memory     = each.value.memory
  bios       = local.bios[each.key]
  boot       = "order=${local.disk_slot[each.key]}"

  # Cloud-init networking only. Admin credentials are baked into the
  # Packer template itself (see winrm_password / preseed user) and
  # deliberately NOT set here — Telmate's provider does not yet support
  # write-only attributes for cipassword, so any value passed through the
  # module would get persisted in the tfstate. The template's default
  # user/password is the source of truth for first-login access.
  ipconfig0 = "ip=dhcp"

  cpu {
    cores   = each.value.cores
    sockets = 1
    type    = "host"
  }
  scsihw = "virtio-scsi-single"

  disk {
    slot    = local.disk_slot[each.key]
    size    = each.value.disk_size
    type    = "disk"
    storage = var.storage_pool
    # iothread only valid with virtio or virtio-scsi-single — disable for SATA
    iothread = !startswith(local.disk_slot[each.key], "sata")
  }

  # Cloud-init drive on ide2. Telmate's linked clone does NOT inherit
  # the template's ide2 cloudinit drive, so we declare it explicitly
  # here so every clone gets a fresh one. Both Linux cloud images and
  # Windows (via Cloudbase-Init) consume the NoCloud datasource from
  # this drive.
  disk {
    slot    = "ide2"
    type    = "cloudinit"
    storage = var.storage_pool
  }

  network {
    id      = 0
    model   = local.network_model[each.key]
    bridge  = var.network_bridge
    macaddr = local.mac_address[each.key]
  }

  # PCI passthrough via Proxmox resource mappings (provider >= 3.0)
  dynamic "pcis" {
    for_each = length(each.value.pci_devices) > 0 ? [1] : []
    content {
      dynamic "pci0" {
        for_each = length(each.value.pci_devices) > 0 ? [each.value.pci_devices[0]] : []
        content {
          mapping {
            mapping_id  = pci0.value.mapping_id
            pcie        = pci0.value.pcie
            primary_gpu = pci0.value.primary_gpu
          }
        }
      }
      dynamic "pci1" {
        for_each = length(each.value.pci_devices) > 1 ? [each.value.pci_devices[1]] : []
        content {
          mapping {
            mapping_id  = pci1.value.mapping_id
            pcie        = pci1.value.pcie
            primary_gpu = pci1.value.primary_gpu
          }
        }
      }
      dynamic "pci2" {
        for_each = length(each.value.pci_devices) > 2 ? [each.value.pci_devices[2]] : []
        content {
          mapping {
            mapping_id  = pci2.value.mapping_id
            pcie        = pci2.value.pcie
            primary_gpu = pci2.value.primary_gpu
          }
        }
      }
      dynamic "pci3" {
        for_each = length(each.value.pci_devices) > 3 ? [each.value.pci_devices[3]] : []
        content {
          mapping {
            mapping_id  = pci3.value.mapping_id
            pcie        = pci3.value.pcie
            primary_gpu = pci3.value.primary_gpu
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      network,
    ]
  }

  sshkeys = <<EOF
  ${var.ssh_key}
  EOF
}

output "vm_ids" {
  value       = { for name, vm in proxmox_vm_qemu.vms : name => vm.vmid }
  description = "Map of VM names to VMIDs"
}
