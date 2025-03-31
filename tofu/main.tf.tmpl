### Module defintions ###
locals {
  module_shared_configurations = {
    # TODO: Separate access rights of ssh keys into separate module
    ssh_key = var.ssh_key
  }
  module_specific_configurations = {
    media = {
      memory    = 4096
      disk_size = "32G"
      vmid      = 101 # This is also used for the ending part of the IP address
    }
    backup = {
      vmid = 102
    }
    network = {
      vmid = 103
    }
    collaboration = {
      memory    = 4096
      disk_size = "32G"
      vmid      = 104
    }
    authentication = {
      memory = 4096
      vmid   = 105
    }
    network = {
      vmid = 107
    }
    dls-server = {
      vmid = 108
    }
    sharing = {
      vmid = 109
    }
  }

  module_configurations = {
    for module_name, specific_configurations in local.module_specific_configurations : module_name => merge(
      local.module_shared_configurations,
      specific_configurations
    )
  }
}

module "container-modules" {
  for_each = local.module_configurations

  source    = "./modules/proxmox-container"
  ssh_key   = each.value.ssh_key
  memory    = try(each.value.memory, var.memory)
  disk_size = try(each.value.disk_size, var.disk_size)
  hostname  = try(each.value.hostname, each.key)
  vmid      = each.value.vmid
  # TODO: Automate so that the VMID grabs the next available instead
}

# module "home-assistant" {
#   source    = "./modules/proxmox-vm"
#   ssh_key   = var.ssh_key
#   clone     = "haos_generic-x86-64-9.5.img"
#   memory    = 4096
#   disk_size = "32G"
#   hostname  = "home-assistant"
#   vmid      = 106
# }

locals {
  # module_instances = values(module.container-modules)

  all_modules =  {
    for module_name, module_config in local.module_configurations : module_name => {
      ansible_host = module.container-modules[module_name].module_ip
      ansible_user = var.user
    }
  }
  host_config = {
    pve = {
      ansible_host               = "192.168.1.100"
      ansible_user               = "root"
      ansible_python_interpreter = "/usr/bin/python3"
    }
  }

  # Merge the static and dynamic hosts to create the final inventory
  all_hosts = merge(local.all_modules, local.host_config)
}

resource "local_file" "inventory_template" {
  filename = "../ansible/inventory"
  # for_each = local.all_modules
  content = yamlencode({
    all = {
      hosts = local.all_hosts
    }
  })
}
