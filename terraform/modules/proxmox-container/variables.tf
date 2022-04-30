variable "ssh_key" {
    type = string
}

variable "image_name" {
    type = string
}

variable "hostname" {
    type = string
}

variable "disk_size" {
    type = string
    default = "8G"
}

variable "private_ip" {
    type = string
}