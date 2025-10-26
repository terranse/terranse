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
    opnsense = {
      source  = "browningluke/opnsense"
      version = ">= 0.1.0"
    }
    caddy = {
      source  = "conradludgate/caddy"
      version = ">= 0.1.0"
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

# TODO: Configure OPNSense provider with actual credentials from secrets
# provider "opnsense" {
#   url    = "https://opnsense.edholm.cc"
#   key    = module.opnsense_secrets.items["api-key"]
#   secret = module.opnsense_secrets.items["api-secret"]
# }

# TODO: Configure Caddy provider - adjust host to match your Caddy admin API endpoint
# provider "caddy" {
#   host = "http://opnsense.edholm.cc:2019"
#   # For SSH tunnel access:
#   # host = "unix:///path/to/admin.sock"
#   # ssh {
#   #   host     = "user@opnsense.edholm.cc:22"
#   #   key_file = "~/.ssh/id_rsa"
#   # }
# }
