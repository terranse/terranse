resource "ansible_host" "debug" {
  for_each = var.configuration

  name      = join(".", [each.key, var.domain])
  groups    = [ each.value.host ]
  variables = {
    host            = jsonencode(each.value.host)
    roles           = jsonencode(join(",", concat(["proxmox/lxc"], try(each.value.roles, []))))
    services        = jsonencode(each.value.services)
    docker_services = jsonencode(each.value.docker_services)
    mounts          = jsonencode(each.value.mounts)
  }
}
