### Common setup ###
terraform {
  required_providers {
    proxmox = {
      source = "telmate/proxmox"
      version = "2.9.6"
    }
  }
}

provider "proxmox" {
  # url is the hostname (FQDN if you have one) for the proxmox host
  pm_api_url = "https://192.168.1.101:8006/api2/json"
  pm_tls_insecure = "true"
  pm_api_token_id = "terraform-prov@pve!terraform-provisioner"
  pm_api_token_secret = "c606811f-789f-4c4d-a7a4-50ad72ac284b"
}

### Module defintions ###
module "media" {
  source     = "./modules/proxmox-container"
  ssh_key    = var.ssh_key
  image_name = var.latest_debian
  hostname   = "media"
  disk_size  = "8G"
  private_ip = "192.168.1.110/24"
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
}
