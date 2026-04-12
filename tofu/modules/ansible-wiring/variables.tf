variable "hosts" {
  type = any
}

variable "ansible_plays" {
  type = list(any)
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
