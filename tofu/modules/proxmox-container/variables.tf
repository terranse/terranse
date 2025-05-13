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

variable "configuration" {
  type = map(any)
  description = "The whole set of lxc containers and their properties"
}

variable "services" {
  type = list(string)
  default = []
  description = "List of enabled services."
}

variable "docker_services" {
  type = list(string)
  description = "List of Docker services."
  default     = []
  validation {
    condition     = !(contains(var.services, "docker")) || length(var.docker_services) > 0
    error_message = "If 'docker' is in 'services', 'docker_services' must not be empty."
  }
}
