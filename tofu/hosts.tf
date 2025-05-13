resource "ansible_host" "physical_hosts" {
  for_each = local.hosts

  name   = each.key
  groups = ["physical_hosts"]
  variables = {
    ansible_host = each.ansible_host
    ansible_user = each.ansible_user
  }
}

