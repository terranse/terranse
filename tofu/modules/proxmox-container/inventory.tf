resource "ansible_host" "debug" {
  for_each = var.configuration

  name      = join(".", [each.key, var.domain])
  groups    = [ "proxmox_containers" ]
  variables = {
    roles           = jsonencode(join(",", concat(["proxmox/lxc"], try(each.value.roles, []))))
    services        = jsonencode(each.value.services)
    docker_services = jsonencode(each.value.docker_services)
    mounts          = jsonencode(each.value.mounts)
  }
}
