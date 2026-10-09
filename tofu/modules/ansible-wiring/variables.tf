variable "hosts" {
  type = any
}

variable "ansible_plays" {
  # `any`, not list(any): a list must hold one element type, but VM plays carry
  # vars_files and container plays do not.
  type = any
}

variable "ansible_root" {
  type = string
}

variable "deployment_name" {
  type = string
}

variable "deployment_path" {
  type        = string
  description = "Relative path from ansible_root to the deployment's tofu dir"
}
