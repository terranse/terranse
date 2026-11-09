module "proxmox-lxc" {
  for_each = {
    for host_key, host in var.hosts : host_key => host
    if try(host.lxcs, null) != null
  }
  source = "../../modules/proxmox-container"

  ansible_root     = local.ansible_root
  host             = each.key
  configuration    = each.value.lxcs
  ssh_key          = var.ssh_key
  domain           = try(each.value.lan_domain, var.domain)
  gateway          = try(each.value.gateway, var.gateway)
  storage_pool     = try(each.value.storage_pool, "local-lvm")
  host_ssh_address = try(each.value.ansible_host, each.key)
}

module "proxmox-vm" {
  for_each = {
    for host_key, host in var.hosts : host_key => host
    if try(host.vms, null) != null
  }
  source = "../../modules/proxmox-vm"

  host          = each.key
  proxmox_node  = try(each.value.proxmox_node, each.key)
  storage_pool  = try(each.value.storage_pool, "local-lvm")
  configuration = each.value.vms
  ssh_key       = var.ssh_key
  domain        = var.domain
}

module "ansible-wiring" {
  source          = "../../modules/ansible-wiring"
  ansible_root    = local.ansible_root
  deployment_name = "sectrinet"
  deployment_path = "../tofu/deployments/sectrinet"
  hosts           = var.hosts
  ansible_plays = flatten(concat(
    [for instance in module.proxmox-lxc : instance.ansible_plays],
    [for instance in module.proxmox-vm : instance.ansible_plays],
  ))
}

# Machines here can share a LAN with the edholm deployment, whose checks cannot
# see this one. A container's MAC is derived from its name alone and its DHCP
# hostname registers in the same DNS, so reusing an edholm name would clash
# with that machine. This deployment has no OPNsense provider on purpose: DNS
# records, reservations and Caddy routes belong to edholm and are out of reach
# from here.
locals {
  lxc_names = flatten([for host in var.hosts : keys(try(host.lxcs, {}))])
  names_taken_by_edholm = [
    for name in local.lxc_names : name
    if length(regexall(
      "(?m)^[ \\t]+\"?${name}\"?[ \\t]*=[ \\t]*\\{",
      file("${path.module}/../edholm/configurations.tfvars"),
    )) > 0
  ]
}

resource "terraform_data" "edholm_name_guard" {
  input = local.lxc_names

  lifecycle {
    precondition {
      condition     = length(local.names_taken_by_edholm) == 0
      error_message = "These machine names are already used by the edholm deployment: ${jsonencode(local.names_taken_by_edholm)}"
    }
  }
}

# TODO: Uncomment and configure when OPNSense and Caddy providers are set up
# Example integration of OPNSense networking module
# This should be configured after:
# 1. Creating a Kea subnet resource in OPNSense
# 2. Obtaining MAC addresses from LXC containers (may need to add to proxmox-container module outputs)
# 3. Configuring provider credentials in secrets
#
# resource "opnsense_kea_subnet" "lan" {
#   subnet      = "192.168.1.0/24"
#   description = "LAN subnet"
# }
#
# module "opnsense-networking" {
#   source = "./modules/opnsense-networking"
#
#   domain        = var.domain
#   kea_subnet_id = opnsense_kea_subnet.lan.id
#
#   # Map LXC containers to their network info
#   # NOTE: MAC addresses need to be added to proxmox-container module outputs
#   lxc_containers = {
#     for host_key, host in var.hosts : host_key => {
#       for lxc_key, lxc in host.lxcs : lxc_key => {
#         ip_address  = "192.168.1.${100 + index(keys(host.lxcs), lxc_key)}"  # Example: assign sequential IPs
#         mac_address = module.proxmox-lxc[host_key].lxc_mac_addresses[lxc_key]  # Need to add this output
#       }
#     }
#   }
#
#   # Map docker services to their reverse proxy config
#   # Service name should match the template file name (e.g., jellyfin.yaml.j2)
#   docker_services = {
#     "jellyfin" = {
#       container_name = "media"  # LXC container hosting the service
#       port           = 8096
#     }
#     "nextcloud" = {
#       container_name = "colab"
#       port           = 80
#     }
#     "authentik" = {
#       container_name = "authentication"
#       port           = 9000
#     }
#   }
#
#   caddy_listen_port = 54443
# }
