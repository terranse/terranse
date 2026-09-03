variable "domain" {
  description = "Base domain for service names"
  type        = string
}

variable "caddy_host" {
  description = "IP of the Caddy host; service DNS records point here"
  type        = string
}

variable "cert_refid" {
  description = "OPNsense certificate refid the plugin exports for Caddy"
  type        = string
}

variable "services" {
  description = "Exposed services with their upstream host"
  type = list(object({
    bundle   = string
    name     = string
    port     = number
    upstream = string
  }))
}

variable "reservations" {
  description = <<-EOT
    Static DHCP reservations, keyed by container name. Pins each container to a
    fixed address using the deterministic MAC derived in proxmox-container, so
    addresses stop moving and Caddy upstreams stay valid.
  EOT
  type = map(object({
    mac = string
    ip  = string
  }))
  default = {}
}

variable "ssh_target" {
  description = "user@host:port style target used to deploy the Caddy drop-in"
  type        = string
  default     = "root@opnsense.edholm.cc"
}

variable "ssh_port" {
  description = "SSH port on the firewall"
  type        = number
  default     = 2223
}
