module "proxmox-lxc" {
  configuration = physical_hosts.lxcs
  for_each      = configuration
  providers     = { proxmox = proxmox.lxc }
  source        = "./modules/proxmox-container"

  # Module interface
  # TODO: Automate so that the VMID grabs the next available instead
  vmid            = each.value.vmid
  ssh_key         = var.ssh_key
  memory          = try(each.value.memory, var.memory)
  disk_size       = try(each.value.disk_size, var.disk_size)
  hostname        = try(each.value.hostname, each.key)
  services        = try(each.value.services, [])
  docker_services = try(each.value.docker_services, [])
}
