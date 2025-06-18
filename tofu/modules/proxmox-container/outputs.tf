# Output back too root module to create Ansible playbook
output "ansible_plays" {
  value = [
    for host_name, host_config in var.configuration : {
      name  = "Configuration of ${host_name}"
      hosts = host_name
      roles = concat(["proxmox/lxc"], try(host_config.roles, []))
      vars  = try(host_config.ansible_vars, {})
    }
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
