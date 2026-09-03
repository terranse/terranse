terraform {
  required_providers {
    proxmox = {
      source  = "registry.terraform.io/telmate/proxmox"
      version = "3.0.2-rc07"
    }
    ansible = {
      source  = "ansible/ansible"
      version = "1.3.0"
    }
    onepassword = {
      source  = "1Password/onepassword"
      version = ">= 2.0.0"
    }
    opnsense = {
      source  = "browningluke/opnsense"
      version = "~> 0.16"
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
  account = "my.1password.com"
}

provider "opnsense" {
  uri        = module.opnsense_secrets.items["url"]
  api_key    = module.opnsense_secrets.items["api-key"]
  api_secret = module.opnsense_secrets.items["api-secret"]

  # The web GUI on :54443 serves its own self-signed certificate
  # (refid 671ffeac69f00), not the ACME wildcard Caddy uses, so verification
  # cannot succeed against it. The path is LAN-only.
  allow_insecure = true
}
