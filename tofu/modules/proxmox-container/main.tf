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

  # A container may bring its own template -- a NixOS rootfs tarball scp'd
  # into the node's vztmpl directory -- instead of the Debian one resolved
  # for the whole node above.
  ostemplate = coalesce(each.value.ostemplate, "local:vztmpl/${local.image_name}")

  # Optional+Computed in the provider, so null sends nothing and leaves no
  # perpetual diff on the containers that do not set it.
  ostype = each.value.ostype

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

  # Resolve through the LAN, never the host. With neither field set, Proxmox
  # copies the host's /etc/resolv.conf into the container, and on a NetBird
  # host that names a resolver the container cannot reach. DHCP used to paper
  # over this by rewriting the file; a static address does not. NixOS is left
  # alone: systemd-resolved owns its resolv.conf (nix/profiles/lxc.nix).
  nameserver   = each.value.ostype == "nixos" ? null : var.gateway
  searchdomain = each.value.ostype == "nixos" ? null : var.domain

  network {
    name   = "eth0"
    bridge = var.network_bridge
    gw     = var.gateway
    # Static when a Debian container has a reservation. Debian 13 brings eth0
    # up with ifupdown2, which skipped DHCP after host reboots (2026-09-20 and
    # 2026-11-15) and left the GitLab runners with no address. A static
    # address also comes up when the DHCP server is not answering yet. The
    # dnsmasq reservation still declares the same name and address, so DNS
    # and the reserved range are unchanged. NixOS stays on DHCP: its
    # systemd-networkd keeps retrying, and the lease is where resolved gets
    # its DNS servers.
    ip = (
      each.value.ostype != "nixos" && contains(keys(var.reserved_ips), each.key)
      ? "${var.reserved_ips[each.key]}/${var.prefix_length}"
      : "dhcp"
    )
    # ip6 is deliberately unset. Any value makes Proxmox write an
    # `iface eth0 inet6 <method>` stanza ahead of the inet one, and ifupdown2
    # in Debian 13 then never starts dhclient and deletes eth0's address
    # (`ifup -n -v`, LXC 109, 2026-11-18). "auto" is worse: the parser
    # rejects the whole file. Nothing here uses global IPv6.
    hwaddr = local.mac_addresses[each.key]
  }
}
