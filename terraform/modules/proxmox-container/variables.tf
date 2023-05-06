variable "ssh_key" {
    type = string
}

variable "image_name" {
    type = string
    default = "debian-11-standard_11.3-1_amd64.tar.zst"
}

variable "hostname" {
    type = string
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

variable "vmid" {
    type = number
}
