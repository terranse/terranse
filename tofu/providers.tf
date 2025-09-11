terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "2.9.14"
    }
    ansible = {
      source  = "ansible/ansible"
      version = "1.3.0"
    }
    onepassword = {
      source  = "1Password/onepassword"
      version = ">= 2.0.0"
    }
  }
  required_version = ">= 1.3.0"
}

provider "proxmox" {
  pm_api_url          = "${module.proxmox_secrets.items["url"]}/api2/json"
  pm_tls_insecure     = "true"
  pm_api_token_id     = module.proxmox_secrets.items["terraform-token-id"]
  pm_api_token_secret = module.proxmox_secrets.items["terraform-api-key"]
}

provider "onepassword" {
  account = "NYDLBZ4TCZARLJQURRIVNK3RZM"
}
