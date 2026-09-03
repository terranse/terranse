locals {
  ansible_root = abspath("${path.module}/../../../ansible")
}

variable "hosts" {
  type = any
}

variable "ssh_key" {
  default = <<EOT
    ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEkdwh5G9JuqNpThbxYqP7RBT9CQJ1fkFeOGuP1sUrXK
  EOT
}

variable "domain" {
  type        = string
  default     = "edholm.cc"
  description = "The top domain where all your services will live"
}

variable "gateway" {
  type        = string
  default     = "192.168.1.1"
  description = "Network gateway IP for this deployment"
}

variable "user" {
  type    = string
  default = "default-user"
}

variable "caddy_host" {
  type        = string
  default     = "192.168.1.1"
  description = "Address of the Caddy host. Every exposed service name resolves here, not to the container behind it, because Caddy terminates TLS and routes by name."
}

variable "opnsense_cert_refid" {
  type        = string
  default     = "64c1e555e19da"
  description = "OPNsense refid of the *.edholm.cc ACME wildcard, which the Caddy plugin exports to /usr/local/etc/caddy/certificates/."
}

variable "lxc_reserved_ips" {
  type        = map(string)
  description = "Fixed address per LXC. Deliberately outside the dnsmasq dynamic range so a reserved address can never be handed to another client first."
  default = {
    authentication = "192.168.1.40"
    backup         = "192.168.1.41"
    colab          = "192.168.1.42"
    dls-server     = "192.168.1.43"
    home           = "192.168.1.44"
    media          = "192.168.1.45"
    network        = "192.168.1.46"
    sharing        = "192.168.1.47"
    tasks          = "192.168.1.48"
    gitlab-runner  = "192.168.1.49"
    vagrant-runner = "192.168.1.50"
  }
}
