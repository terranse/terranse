locals {
  ansible_root = abspath("${path.module}/../../../ansible")
}

variable "hosts" {
  type = map(any)
}

variable "ssh_key" {
  default = <<EOT
    ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEkdwh5G9JuqNpThbxYqP7RBT9CQJ1fkFeOGuP1sUrXK
  EOT
}

variable "domain" {
  type        = string
  default     = "sectrinet.com"
  description = "The top domain where all your services will live"
}

variable "gateway" {
  type        = string
  default     = "192.168.40.1"
  description = "Network gateway IP for this deployment"
}

variable "user" {
  type = string
  default = "default-user"
}
