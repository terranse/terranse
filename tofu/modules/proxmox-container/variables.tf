variable "ansible_root" {
  type = string
}

variable "ssh_key" {
  type = string
}

variable "image_name" {
  type    = string
  default = "debian-13-standard_13.1-1_amd64.tar.zst"
}

variable "host" {
  type = string
}

variable "domain" {
  type = string
}

variable "storage_pool" {
  description = "Proxmox storage pool for container rootfs"
  type        = string
  default     = "FastStorage"
}

variable "network_bridge" {
  description = "Proxmox network bridge"
  type        = string
  default     = "vmbr0"
}

variable "gateway" {
  description = "Network gateway IP"
  type        = string
}

variable "configuration" {
  description = "Map of LXC configurations"
  type = map(object({
    memory          = optional(number, 2048)
    cores           = optional(number, 2)
    disk_size       = optional(string, "8G")
    vmid            = optional(number)
    mounts          = optional(map(map(string)), {})
    roles           = optional(list(object({ name = string })), [])
    services        = optional(list(object({ name = string })), [])
    docker_services = optional(list(object({ name = string })), [])
  }))
}

variable "host_ssh_address" {
  description = "SSH-reachable address for the target Proxmox node (defaults to var.host)"
  type        = string
  default     = null
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
}

module "validate_common" {
  source         = "../validation"
  ansible_root   = var.ansible_root
  machine_common = {
    roles           = try(var.configuration.roles, [])
    services        = try(var.configuration.services, [])
    docker_services = try(var.configuration.docker_services, [])
  }
}

# variable "force_recreate_trigger" {
#   description = "Trigger to force recreation of the container"
#   type        = any
#   default     = null
# }
