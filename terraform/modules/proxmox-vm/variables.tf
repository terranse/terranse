variable "ssh_key" {
    type = string
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
    default = "10G"
}

variable "vmid" {
    type = string
}
