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
    ansible_host = try(each.value.ansible_host, null)
    ansible_user = each.value.ansible_user
  }
}

locals {
  all_container_hosts = join(":", [for play in var.ansible_plays : play.hosts])

  host_plays = [
    for host_key, host in var.hosts : {
      name  = "Configure host: ${host_key}"
      hosts = host_key
      roles = [
        for r in try(host.host_roles, []) :
        { role = r.name, vars = try(r.vars, {}) }
      ]
      vars = {}
    }
    if try(host.host_roles, null) != null && length(try(host.host_roles, [])) > 0
  ]
}

resource "local_file" "ansible_playbook" {
  filename = "${var.ansible_root}/playbooks/${var.deployment_name}.yaml"
  content = yamlencode(concat(local.host_plays, var.ansible_plays, [{
    name  = "Harden SSH - disable root login on all containers"
    hosts = local.all_container_hosts
    tasks = [
      {
        name = "Disable SSH root login"
        become = true
        lineinfile = {
          path   = "/etc/ssh/sshd_config"
          regexp = "^PermitRootLogin"
          line   = "PermitRootLogin no"
          state  = "present"
        }
        register = "sshd_changed"
      },
      {
        name = "Restart SSH to apply changes"
        become = true
        service = {
          name  = "ssh"
          state = "restarted"
        }
        when = "sshd_changed.changed"
      }
    ]
  }]))
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
