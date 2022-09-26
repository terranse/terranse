variable "ssh_key" {
    type = string
}

variable "image_name" {
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
    default = "8G"
}

variable "vmid" {
    type = number
}
