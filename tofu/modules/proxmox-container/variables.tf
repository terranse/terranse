variable "ssh_key" {
  type = string
}

variable "image_name" {
  type = string
  default = "debian-11-standard_11.3-1_amd64.tar.zst"
}

variable "host" {
  type = string
}

variable "domain" {
  type = string
}

variable "vmid" {
  type = number
  default = 1 # Dummy value
  description = "The VMID to use for the container."
}

variable "configuration" {
  description = "Map of LXC configurations"
  type = map(object({
    memory          = optional(number)
    cores           = optional(number)
    disk_size       = optional(string)
    vmid            = optional(number)
    mounts          = optional(map(object({
      zfs_dataset   = string
      ct_mountpoint = string
    })), {})
    roles           = optional(list(string), [])
    services        = optional(list(string), [])
    docker_services = optional(list(string), [])
  }))

  validation {
    # Ensure that docker is installed as a service if "docker_services" are declared
    condition = length([
      for name, config in var.configuration : name
      if length(try(config.docker_services, [])) > 0 && 
        !contains(try(config.services, []), "docker")
    ]) == 0

    error_message = join(" ", concat(
      ["The following LXCs have 'docker_services' defined but 'docker' is not declared in 'services':\n"],
      [for name, config in var.configuration : name
      if length(try(config.docker_services, [])) > 0 && 
          !contains(try(config.services, []), "docker")
      ]
    ))
  }
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
