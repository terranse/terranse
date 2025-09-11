variable "ssh_key" {
  default = <<EOT
    ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEkdwh5G9JuqNpThbxYqP7RBT9CQJ1fkFeOGuP1sUrXK
  EOT
}

variable "domain" {
  type = string
  default = "edholm.cc"
  description = "The top domain where all your services will live"
}

variable "user" {
  type = string
  default = "default-user"
}
