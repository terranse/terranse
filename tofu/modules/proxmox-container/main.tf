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
  # Deterministic MAC per container, inside Proxmox's BC:24:11 OUI. Derived
  # from the container name so it is known at plan time: a DHCP reservation
  # does not have to wait for the container to exist, and rebuilding one
  # preserves its address.
  #
  # Changing this derivation moves every container's MAC, and therefore every
  # DHCP lease. `media` must hash to BC:24:11:72:1C:95.
  mac_addresses = {
    for n in keys(var.configuration) : n => upper(join(":", [
      "BC", "24", "11",
      substr(sha256(n), 0, 2),
      substr(sha256(n), 2, 2),
      substr(sha256(n), 4, 2),
    ]))
  }
}

resource "terraform_data" "mac_collision_guard" {
  input = local.mac_addresses

  lifecycle {
    precondition {
      condition     = length(distinct(values(local.mac_addresses))) == length(local.mac_addresses)
      error_message = "Deterministic MAC collision across containers on this host: ${jsonencode(local.mac_addresses)}"
    }
  }
}

data "external" "resolve_lxc_template" {
  program = ["${path.module}/resolve-template.sh"]
  query   = { prefix = var.image_prefix }
}

locals {
  image_name = data.external.resolve_lxc_template.result.name
}

resource "terraform_data" "ensure_lxc_template" {
  input = local.image_name

  provisioner "local-exec" {
    command = <<-EOT
      ssh root@${coalesce(var.host_ssh_address, var.host)} \
        "pveam list local | grep -q '${local.image_name}' \
         || (pveam update && pveam download local ${local.image_name})"
    EOT
  }
}

resource "proxmox_lxc" "lxcs" {
  for_each   = var.configuration
  depends_on = [terraform_data.ensure_lxc_template]

  vmid        = try(each.value.vmid, 0)
  target_node = var.host
  hostname    = each.key
  ostemplate  = "local:vztmpl/${local.image_name}"

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
    ignore_changes  = [features, ostemplate]
    # TODO: Never got this to work.
    # replace_triggered_by = [
    #   # This will come from the root module
    #   var.force_recreate_trigger
    # ]
  }

  // Terraform will crash without rootfs defined
  rootfs {
    storage = var.storage_pool
    size    = each.value.disk_size
  }

  network {
    name   = "eth0"
    bridge = var.network_bridge
    gw     = var.gateway
    ip     = "dhcp"
    ip6    = "auto"
    hwaddr = local.mac_addresses[each.key]
  }
}
