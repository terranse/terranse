resource "ansible_host" "vm_hosts" {
  for_each = var.configuration

  name   = join(".", [each.key, var.domain])
  groups = [var.host, "vms"]
  variables = {
    host  = jsonencode(var.host)
    roles = jsonencode(each.value.roles)
    # Cloud-init VMs (unlike the LXCs) refuse root SSH; connect as the cloud
    # image's default user and escalate. Passwordless sudo is baked into the
    # image, so become needs no password.
    ansible_user   = each.value.ci_user
    ansible_become = "true"
  }
}

output "ansible_plays" {
  value = [
    for name, config in var.configuration : {
      name  = "Configuration of ${name}"
      hosts = "${name}.${var.domain}"
      roles = [for r in config.roles : { role = r.name, vars = r.vars }]
      vars  = {}
    }
    if length(config.roles) > 0
  ]
}
