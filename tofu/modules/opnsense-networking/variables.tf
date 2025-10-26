variable "domain" {
  description = "Base domain for DNS overrides and reverse proxy hostnames"
  type        = string
}

variable "kea_subnet_id" {
  description = "Kea DHCP subnet ID for reservations (resource ID from opnsense_kea_subnet)"
  type        = string
}

variable "lxc_containers" {
  description = "Map of LXC containers with their network configuration. MAC address must be obtained from proxmox provider outputs if available."
  type = map(object({
    ip_address  = string
    mac_address = string
  }))
  default = {}
}

variable "docker_services" {
  description = "Map of Docker services to configure reverse proxy for. The key is the service name (used as subdomain and should match ansible template file name), and the value contains container details."
  type = map(object({
    container_name = string
    port           = number
  }))
  default = {}

  validation {
    condition     = alltrue([for k, v in var.docker_services : can(regex("^[a-z0-9-]+$", k))])
    error_message = "Service names must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "caddy_listen_port" {
  description = "Port for Caddy to listen on"
  type        = number
  default     = 54443
}
