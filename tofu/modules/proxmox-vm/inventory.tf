locals {
  # Connect to a statically-addressed VM by IP, not by name. The LAN's DNS is
  # split-horizon and answers <vm>.<domain> with the *WAN* address, and there is
  # no hairpin NAT — so resolving the inventory hostname from inside the LAN
  # reaches nothing at all. Fall back to the FQDN for DHCP VMs, which have no
  # address to know ahead of time.
  ansible_hosts = {
    for name, vm in var.configuration : name => try(
      regex("ip=([0-9.]+)/", coalesce(vm.ipconfig, ""))[0],
      join(".", [name, var.domain])
    )
  }
}

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
    ansible_host   = local.ansible_hosts[each.key]
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
