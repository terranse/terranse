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
