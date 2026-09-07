# Output back too root module to create Ansible playbook
output "ansible_plays" {
  value = [
    for host_name, host_config in var.configuration : {
      name  = "Configuration of ${host_name}"
      hosts = "${host_name}.${var.domain}"
      roles = concat(
        [{ role = "proxmox/lxc", vars = {} }],
        try([for r in host_config.roles : { role = r.name, vars = try(r.vars, {}) }], [])
      )
      vars  = try(host_config.ansible_vars, {})
    }
    # A `provision = "none"` container is declared in nix/machines.nix and
    # Ansible must never touch it. Dropping its play here does two jobs: it
    # skips the apt-based proxmox/lxc role, and -- because ansible-wiring
    # builds the "Harden SSH" play's host list by joining these plays' hosts
    # -- it also keeps that play away, which would otherwise try to edit a
    # read-only /etc/ssh/sshd_config and restart a service named `ssh` that
    # does not exist on NixOS. The inventory entry is emitted separately in
    # inventory.tf and is unaffected.
    if host_config.provision != "none"
  ]
}

# Output back to root module in order to control what part
# of LXC changes triggers a recreation of the unit
output "ansible_inventory" {
  value = {
    for name, entry in ansible_host.lxc_hosts :
      name => entry
  }
}

output "lxc_mac_addresses" {
  description = "Deterministic MAC per LXC, for dnsmasq reservations"
  value       = local.mac_addresses
}
