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
}

provider "proxmox" {
  alias = "lxc"
  pm_api_url          = "${local.proxmox.ip}/api2/json"
  pm_tls_insecure     = "true"
  pm_api_token_id     = local.proxmox.terraform-token-id
  pm_api_token_secret = local.proxmox.terraform-token-secret
}

provider "onepassword" {
  account = "NYDLBZ4TCZARLJQURRIVNK3RZM"
}
