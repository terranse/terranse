### Common setup ###
terraform {
  required_providers {
    proxmox = {
      source = "telmate/proxmox"
      version = "2.9.10"
    }
  }
}

provider "proxmox" {
  # url is the hostname (FQDN if you have one) for the proxmox host
  pm_api_url = "https://192.168.1.100:8006/api2/json"
  pm_tls_insecure = "true"
  pm_api_token_id = "terraform-prov@pve!terraform-token"
  pm_api_token_secret = "***REMOVED***"
}

### Module defintions ###
# Note that the module, hostname and ansible .yaml files must all have the same names currently
module "media" {
  source     = "./modules/proxmox-container"
  ssh_key    = var.ssh_key
  image_name = var.latest_debian
  memory     = 4096
  hostname   = "media"
  vmid       = 101 # This is also used for the ending part of the IP address
}

module "backup" {
  source     = "./modules/proxmox-container"
  ssh_key    = var.ssh_key
  image_name = var.latest_debian
  hostname   = "backup"
  vmid       = 102
}

module "network" {
  source     = "./modules/proxmox-container"
  ssh_key    = var.ssh_key
  image_name = var.latest_debian
  hostname   = "network"
  vmid       = 103
}


# module "home-assistant" {
#   source = "./modules/proxmox-vm"
#   ssh_key = var.ssh_key
#   clone = "https://github.com/home-assistant/operating-system/releases/download/9.3/haos_ova-9.3.qcow2.xz"
#   memory = 4096
#   disk_size = "32G"
#   hostname = "home-assistant"
#   vmid = 105
# }
# This is for updating an Ansible inventory containing the below given variables
# This list must be updated for every new module, as well as the corresponding "inventory.tmpl"
resource "local_file" "ansible_inventory" {
  content = templatefile("inventory.tmpl", { 
    # home-assistant_ip = module.home-assistant.module_ip,
    user              = var.user,
    # key_path = var.key_path
  })
  filename = "../ansible/inventory"
  depends_on = [
    module.media,
    module.backup,
    # module.home-assistant
  ]
}
