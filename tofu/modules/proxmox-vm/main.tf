terraform {
  required_providers {
    proxmox = {
      source  = "registry.terraform.io/telmate/proxmox"
      version = "3.0.2-rc07"
    }
    ansible = {
      source  = "ansible/ansible"
      version = "1.3.0"
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

  # Resolve vgpu_slice_gb to mdev type using vgpu_profiles lookup.
  resolved_pci_devices = {
    for name, vm in var.configuration : name => [
      for dev in vm.pci_devices : merge(dev, {
        mdev = coalesce(dev.mdev, try(var.vgpu_profiles[tostring(dev.vgpu_slice_gb)], null))
      })
    ]
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

  agent              = 1
  os_type            = local.os_type[each.key]
  clone              = each.value.clone
  full_clone         = each.value.full_clone
  memory             = each.value.memory
  bios               = local.bios[each.key]
  boot               = "order=${local.disk_slot[each.key]}"
  start_at_node_boot = each.value.onboot

  # Cloud-init networking only. Admin credentials are baked into the
  # Packer template itself (see winrm_password / preseed user) and
  # deliberately NOT set here — Telmate's provider does not yet support
  # write-only attributes for cipassword, so any value passed through the
  # module would get persisted in the tfstate. The template's default
  # user/password is the source of truth for first-login access.
  ipconfig0 = coalesce(each.value.ipconfig, "ip=dhcp")

  # DHCP hands out DNS with the lease; a static ipconfig does not. Without these
  # a statically-addressed guest comes up with an empty resolv.conf and every
  # name lookup hangs — apt in particular retries for many minutes before failing.
  nameserver   = each.value.nameserver
  searchdomain = each.value.searchdomain

  cpu {
    cores   = each.value.cores
    sockets = 1
    type    = "host"
  }
  scsihw = "virtio-scsi-single"

  # ORDER MATTERS. Telmate diffs `disk` blocks positionally, and reads them back
  # from Proxmox sorted by slot — so ide2 always comes back before scsi0/sata0/
  # virtio0. Declaring the data disk first therefore produces a permanent phantom
  # diff in which the two blocks swap slots (boot disk -> cloudinit and back),
  # which an in-place apply would happily carry out. Keep ide2 declared first.
  #
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

  disk {
    slot    = local.disk_slot[each.key]
    size    = each.value.disk_size
    type    = "disk"
    storage = var.storage_pool
    # Every VM disk here is block-backed (ZFS zvol or whole disk), never a
    # qcow2/file-backed image, so raw is fleet-wide reality, not per-VM
    # config. Declaring it explicitly stops the provider from reporting a
    # phantom drift (it otherwise reads "raw" back from Proxmox but has no
    # value to compare it against, since nothing set it in config).
    format = "raw"
    # iothread only valid with virtio or virtio-scsi-single — disable for SATA
    iothread = !startswith(local.disk_slot[each.key], "sata")
  }

  network {
    id      = 0
    model   = local.network_model[each.key]
    bridge  = var.network_bridge
    macaddr = local.mac_address[each.key]
  }

  # PCI passthrough via Proxmox resource mappings or raw PCI addresses (provider >= 3.0)
  dynamic "pcis" {
    for_each = length(local.resolved_pci_devices[each.key]) > 0 ? [1] : []
    content {
      dynamic "pci0" {
        for_each = length(local.resolved_pci_devices[each.key]) > 0 ? [local.resolved_pci_devices[each.key][0]] : []
        content {
          dynamic "mapping" {
            for_each = pci0.value.mapping_id != null ? [1] : []
            content {
              mapping_id  = pci0.value.mapping_id
              mdev        = pci0.value.mdev
              pcie        = pci0.value.pcie
              primary_gpu = pci0.value.primary_gpu
              rombar      = pci0.value.rombar
            }
          }
          dynamic "raw" {
            for_each = pci0.value.raw_id != null ? [1] : []
            content {
              raw_id      = pci0.value.raw_id
              mdev        = pci0.value.mdev
              pcie        = pci0.value.pcie
              primary_gpu = pci0.value.primary_gpu
              rombar      = pci0.value.rombar
            }
          }
        }
      }
      dynamic "pci1" {
        for_each = length(local.resolved_pci_devices[each.key]) > 1 ? [local.resolved_pci_devices[each.key][1]] : []
        content {
          dynamic "mapping" {
            for_each = pci1.value.mapping_id != null ? [1] : []
            content {
              mapping_id  = pci1.value.mapping_id
              mdev        = pci1.value.mdev
              pcie        = pci1.value.pcie
              primary_gpu = pci1.value.primary_gpu
              rombar      = pci1.value.rombar
            }
          }
          dynamic "raw" {
            for_each = pci1.value.raw_id != null ? [1] : []
            content {
              raw_id      = pci1.value.raw_id
              mdev        = pci1.value.mdev
              pcie        = pci1.value.pcie
              primary_gpu = pci1.value.primary_gpu
              rombar      = pci1.value.rombar
            }
          }
        }
      }
      dynamic "pci2" {
        for_each = length(local.resolved_pci_devices[each.key]) > 2 ? [local.resolved_pci_devices[each.key][2]] : []
        content {
          dynamic "mapping" {
            for_each = pci2.value.mapping_id != null ? [1] : []
            content {
              mapping_id  = pci2.value.mapping_id
              mdev        = pci2.value.mdev
              pcie        = pci2.value.pcie
              primary_gpu = pci2.value.primary_gpu
              rombar      = pci2.value.rombar
            }
          }
          dynamic "raw" {
            for_each = pci2.value.raw_id != null ? [1] : []
            content {
              raw_id      = pci2.value.raw_id
              mdev        = pci2.value.mdev
              pcie        = pci2.value.pcie
              primary_gpu = pci2.value.primary_gpu
              rombar      = pci2.value.rombar
            }
          }
        }
      }
      dynamic "pci3" {
        for_each = length(local.resolved_pci_devices[each.key]) > 3 ? [local.resolved_pci_devices[each.key][3]] : []
        content {
          dynamic "mapping" {
            for_each = pci3.value.mapping_id != null ? [1] : []
            content {
              mapping_id  = pci3.value.mapping_id
              mdev        = pci3.value.mdev
              pcie        = pci3.value.pcie
              primary_gpu = pci3.value.primary_gpu
              rombar      = pci3.value.rombar
            }
          }
          dynamic "raw" {
            for_each = pci3.value.raw_id != null ? [1] : []
            content {
              raw_id      = pci3.value.raw_id
              mdev        = pci3.value.mdev
              pcie        = pci3.value.pcie
              primary_gpu = pci3.value.primary_gpu
              rombar      = pci3.value.rombar
            }
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      network,
      # Proxmox records order/shutdown_timeout/startup_delay = -1 out-of-band
      # for any VM with no explicit start/shutdown ordering (i.e. every VM
      # this module manages), and the provider then reads that back as a
      # diff against an undeclared block on every plan. There is nothing to
      # declare that would satisfy it — it's provider/API bookkeeping, not
      # config drift — so ignore the block instead of fighting it.
      startup_shutdown,
      # Power state is managed by hand (and later by gpu-manager), not by
      # tofu. `gaming` and `ai-vm` share a single 24Q slice of the A5000 and
      # must never run at once, so stopping one to free the GPU is normal
      # operation — but the provider defaults vm_state to "running", which
      # made every plan want to start both and hand the loser a vGPU the
      # card cannot create. VMs are still started when first created;
      # only later reconciliation is dropped.
      vm_state,
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
