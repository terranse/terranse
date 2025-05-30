terraform {
  required_providers {
    proxmox = {
      source = "telmate/proxmox"
      version = ">= 2.9.14"
    }
    ansible = {
      source  = "ansible/ansible"
      version = "1.3.0"
    }
  }
}

locals {
  module_ip = "192.168.1.${var.vmid}"
}
resource "proxmox_lxc" "lxcs" {
  for_each = var.configuration

  vmid         = each.value.vmid
  target_node  = var.host
  hostname     = each.key
  ostemplate   = "local:vztmpl/${var.image_name}"

  cores  = each.value.cores
  memory = each.value.memory

  unprivileged = true
  onboot       = true
  start        = true

  ssh_public_keys = <<EOT
    ${var.ssh_key}
  EOT

  features {
    nesting = true
    # fuse    = true
    # mknod   = true
    # keyctl  = true # This line is not permitted do perform by our terraform user -- set up in Ansible later instead, when Docker is needed
  }

  # Because keyctl cannot be changed by Terraform, but it would try to update this value to false (default), this would break tf runtime
  lifecycle {
    prevent_destroy = false
    ignore_changes  = [features, ]
  }

  // Terraform will crash without rootfs defined
  rootfs {
    storage = "FastStorage"
    size    = each.value.disk_size
  }

  network {
    name   = "eth0"
    bridge = "vmbr0"
    gw     = "192.168.1.1"
    ip     = "${local.module_ip}/24"
    ip6    = "auto"
  }
}

// This is needed for a module to make values available to the calling root module
output "module_ip" {
  value = local.module_ip
}
