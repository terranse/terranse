output "dhcp_reservations" {
  description = "Map of DHCP reservations created"
  value = {
    for k, v in opnsense_kea_reservation.lxc_dhcp : k => {
      hostname    = v.hostname
      ip_address  = v.ip_address
      mac_address = v.mac_address
      id          = v.id
    }
  }
}

output "dns_overrides" {
  description = "Map of DNS domain overrides created"
  value = {
    for k, v in opnsense_unbound_domain_override.lxc_dns : k => {
      domain  = v.domain
      server  = v.server
      enabled = v.enabled
      id      = v.id
    }
  }
}

output "reverse_proxy_endpoints" {
  description = "Map of reverse proxy endpoints configured in Caddy"
  value = {
    for k, v in var.docker_services : k => {
      public_url  = "http://${k}.${var.domain}:${var.caddy_listen_port}"
      upstream    = "${v.container_name}.${var.domain}:${v.port}"
      listen_port = var.caddy_listen_port
    }
  }
}

output "caddy_server_names" {
  description = "Names of Caddy server resources created"
  value       = { for k, v in caddy_server.docker_service_proxies : k => v.name }
}
