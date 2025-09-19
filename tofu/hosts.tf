# This exposes the physical hosts that should be configured by Ansible
# into its own group "physical_hosts".
resource "ansible_host" "physical_hosts" {
  for_each = var.hosts

  name   = each.key
  groups = ["physical_hosts"]
  variables = {
    ansible_host = each.value.ansible_host
    ansible_user = each.value.ansible_user
  }
}

# This enables a more flexible configuration of the hosts,
# while still keeping the possibility to validate common variables
variable "hosts" {
  type = map(any)
}
