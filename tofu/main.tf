module "proxmox-lxc" {
  for_each = var.hosts
  source   = "./modules/proxmox-container"

  # Module interface
  ansible_root  = local.ansible_root
  host          = each.key
  configuration = each.value.lxcs
  # Use a base VMID per host, then use index in lxcs
  # TODO: This will probably break when VMs are added to the mix
  ssh_key       = var.ssh_key
  domain        = var.domain

  # TODO: This method of only rerunning the Ansible playbooks for affected host
  # configs did not work. Keeping to attempt to fix it later.
  # force_recreate_trigger = terraform_data.trigger_recreate[each.key]
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
