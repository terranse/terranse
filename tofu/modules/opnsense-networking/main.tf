terraform {
  required_providers {
    opnsense = {
      source  = "browningluke/opnsense"
      version = ">= 0.1.0"
    }
    caddy = {
      source  = "conradludgate/caddy"
      version = ">= 0.1.0"
    }
  }
}

# Create Kea DHCP reservations for each LXC container
resource "opnsense_kea_reservation" "lxc_dhcp" {
  for_each = var.lxc_containers

  subnet_id   = var.kea_subnet_id
  ip_address  = each.value.ip_address
  mac_address = each.value.mac_address
  hostname    = each.key
  description = "DHCP reservation for ${each.key}"
}

# Create Unbound DNS domain overrides for each LXC container
resource "opnsense_unbound_domain_override" "lxc_dns" {
  for_each = var.lxc_containers

  domain      = "${each.key}.${var.domain}"
  server      = each.value.ip_address
  description = "DNS override for ${each.key}"
  enabled     = true
}

# Create Caddy reverse proxy configurations for docker services
# The template file name is used as the reverse proxy target
resource "caddy_server" "docker_service_proxies" {
  for_each = var.docker_services

  name   = each.key
  listen = [":${var.caddy_listen_port}"]

  route {
    match {
      host = ["${each.key}.${var.domain}"]
    }

    handler {
      reverse_proxy {
        upstream {
          dial = "${each.value.container_name}.${var.domain}:${each.value.port}"
        }
      }
    }
  }
}

# Optional: Create firewall rules for Caddy reverse proxy access
# Uncomment if opnsense provider supports firewall rules
# resource "opnsense_firewall_rule" "caddy_access" {
#   for_each = var.docker_services
#
#   action      = "pass"
#   interface   = var.firewall_interface
#   protocol    = "tcp"
#   source      = "any"
#   destination = var.caddy_listen_address
#   destination_port = var.caddy_listen_port
#   description = "Allow access to Caddy reverse proxy for ${each.key}"
#   enabled     = true
# }
