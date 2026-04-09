terraform {
  required_providers {
    proxmox = {
      source  = "registry.terraform.io/telmate/proxmox"
      version = "3.0.2-rc07"
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
  account = "Our Family"
}
