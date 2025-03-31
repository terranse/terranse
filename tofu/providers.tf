terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "2.9.14"
    }
  }
}

provider "proxmox" {
  pm_api_url          = "https://192.168.1.100:8006/api2/json"
  pm_tls_insecure     = "true"
  pm_api_token_id     = "terraform-prov@pve!terraform-token"
  pm_api_token_secret = "op://HomeNetwork/Proxmox/terraform-api-key"
}

