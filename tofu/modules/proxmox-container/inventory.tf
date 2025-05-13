resource "ansible_host" "debug" {
  for_each = var.configuration

  name   = each.hostname + var.domain
  groups = [ "proxmox_containers" ]
  variables = {
    roles = [
      "proxmox/lxc"
    ]
    mounts = each.mounts
  }
}
