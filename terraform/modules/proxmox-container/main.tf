terraform {
  required_providers {
    proxmox = {
      source = "telmate/proxmox"
      version = "2.9.6"
    }
  }
}

resource "proxmox_lxc" "test_ct" {
  target_node  = "proxmox"
  hostname     = var.hostname
  ostemplate   = "local-btrfs:vztmpl/${var.image_name}"
  unprivileged = true
  onboot       = true

  ssh_public_keys = <<-EOT
    ${var.ssh_key}
  EOT

  features {
    nesting = true
  }

  // Terraform will crash without rootfs defined
  rootfs {
    storage = "FastStorage"
    size    = var.disk_size
  }

  network {
    name   = "eth0"
    bridge = "vmbr0"
    ip     = var.private_ip
    ip6    = "auto"
  }

  provisioner "local-exec" {
    command     = "ansible-playbook -i inventory roles/$(var.hostname).yaml"
    working_dir = "../../../ansible"
  }
}

// This is needed for a module to make values available to the calling root module
output "module_ip" {
  value = var.private_ip
}