# Inventory entry
resource "ansible_host" "lxc_hosts" {
  for_each = var.configuration

  name      = join(".", [each.key, var.domain])
  groups    = [ var.host ]
  variables = {
    host            = jsonencode(var.host)
    services        = jsonencode(each.value.services)
    docker_services = jsonencode(each.value.docker_services)
    mounts          = jsonencode(each.value.mounts)
  }
}
