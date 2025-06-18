module "proxmox-lxc" {
  for_each = local.hosts
  source   = "./modules/proxmox-container"

  # Module interface
  host            = each.key
  configuration   = each.value.lxcs
  # Use a base VMID per host, then use index in lxcs
  # TODO: This will probably break when VMs are added to the mix
  vmid            = 100 + (index(keys(local.hosts), each.key) * 100)
  ssh_key         = var.ssh_key
  domain          = var.domain

  # TODO: This method of only rerunning the Ansible playbooks for affected host
  # configs did not work. Keeping to attempt to fix it later.
  # force_recreate_trigger = terraform_data.trigger_recreate[each.key]
}
