variable "ansible_root" {
  type        = string
  default     = "../../ansible"
  description = "Absolute path to the ansible directory"
  # TODO: Add validation that it exists and has roles/ subdirectory
}

variable "machine_common" {
  description = "Common fields to validate for any machine type"
  type = object({
    roles           = optional(list(object({ name = string })), [])
    services        = optional(list(object({ name = string })), [])
    docker_services = optional(list(object({ name = string })), [])
    # TODO: Add more validations, e.g. that mount points is an existing ZFS dataset
  })

  # Roles must exist under ansible/roles
  validation {
    condition = alltrue([
      for r in var.machine_common.roles :
      length(fileset("${var.ansible_root}/roles", "**/${r.name}/**")) > 0
    ])
    error_message = "One or more roles do not exist (or are empty) under ansible/roles/."
  }

  # Services must exist under ansible/roles/services
  validation {
    condition = alltrue([
      for s in var.machine_common.services :
      length(fileset("${var.ansible_root}/roles/services", "**/${s.name}/**")) > 0
    ])
    error_message = "One or more services do not exist (or are empty) under ansible/roles/services/."
  }

  # Docker service templates must exist
  validation {
    condition = alltrue([
      for d in var.machine_common.docker_services :
      fileexists("${var.ansible_root}/roles/services/docker/templates/${d.name}.yaml.j2")
    ])
    error_message = "One or more docker services lack a .yaml.j2 template under ansible/roles/services/docker/templates/."
  }

  # To run docker services it also needs to have docker setup
  validation {
    condition     = !(contains(var.machine_common.services, "docker")) || length(var.machine_common.docker_services) > 0
    error_message = "If 'docker' is in 'services', 'docker_services' must not be empty."
  }
}
