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
