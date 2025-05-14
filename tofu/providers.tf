terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      configuration_aliases = [ proxmox.lxc ]
      version = "2.9.14"
    }
    ansible = {
      source  = "ansible/ansible"
      version = "1.3.0"
    }
  }
}
