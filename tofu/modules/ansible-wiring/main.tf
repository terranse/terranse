terraform {
  required_providers {
    ansible = {
      source  = "ansible/ansible"
      version = "1.3.0"
    }
  }
}

resource "ansible_host" "physical_hosts" {
  for_each = var.hosts

  name   = each.key
  groups = ["physical_hosts"]
  variables = {
    ansible_host = jsonencode(try(each.value.ansible_host, null))
    ansible_user = jsonencode(each.value.ansible_user)
  }
}

resource "local_file" "ansible_playbook" {
  filename = "${var.ansible_root}/playbooks/${var.deployment_name}.yaml"
  content  = yamlencode(var.ansible_plays)
}

resource "local_file" "ansible_inventory" {
  filename = "${var.ansible_root}/inventory/${var.deployment_name}.yaml"
  content  = yamlencode({
    plugin               = "cloud.terraform.terraform_provider"
    project_path         = var.deployment_path
    search_child_modules = true
    binary_path          = "tofu"
  })
}
