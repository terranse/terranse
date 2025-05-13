# Fill it will variables, e.g. ssh keys, hostnames, etc

variable "ssh_key" {
  default = <<EOT
    ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEkdwh5G9JuqNpThbxYqP7RBT9CQJ1fkFeOGuP1sUrXK
  EOT
}

# TODO: Automatically download and create new tags for different CT images
variable "latest_debian" {
  type    = string
  default = "debian-11-standard_11.3-1_amd64.tar.zst"
}

# data "github_release" "example" {
#     repository  = "operating-system"
#     owner       = "home-assistant"
#     retrieve_by = "latest"
# }

variable "image_name" {
    type = string
    default = "debian-11-standard_11.3-1_amd64.tar.zst"
}

variable "hostname" {
    type = string
    default = "dummy"
}

variable "cores" {
  type = string
  default = "2"
}

variable "memory" {
  type = string
  default = "1024"
}

variable "disk_size" {
    type = string
    default = "8G"
}

# This is also used for the ending part of the IP address
variable "vmid" {
    type = number
    default = 1 # Dummy value
}

variable "user" {
  type = string
  # default = "terraform-prov"
  default = "root"
}
