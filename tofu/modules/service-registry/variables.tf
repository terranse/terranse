variable "bundles" {
  description = "Docker service bundle names; each must have <bundle>.yaml.j2 in template_dir"
  type        = list(string)
}

variable "template_dir" {
  description = "Directory holding the Ansible docker compose templates"
  type        = string
}
