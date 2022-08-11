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
  hostname   = "media"
  vmid       = 101 # This is also used for the ending part of the IP address
}

# This is for updating an Ansible inventory containing the below given variables
# This list must be updated for every new module, as well as the corresponding "inventory.tmpl"
resource "local_file" "ansible_inventory" {
  content = templatefile("inventory.tmpl", { 
    media_ip = module.media.module_ip,
    user     = var.user,
    # key_path = var.key_path
  })
  filename = "../ansible/inventory"
  depends_on = [
    module.media
  ]
}
