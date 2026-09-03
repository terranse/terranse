module "proxmox_secrets" {
  source = "../../modules/secrets/1password/"

  providers = {
    onepassword = onepassword
  }

  account = "NYDLBZ4TCZARLJQURRIVNK3RZM"
  vault   = "f4h63aecdn7rpzx4sbzyw35jee"
  item    = "Proxmox"
}

module "opnsense_secrets" {
  source = "../../modules/secrets/1password/"

  providers = {
    onepassword = onepassword
  }

  account = "NYDLBZ4TCZARLJQURRIVNK3RZM"
  vault   = "f4h63aecdn7rpzx4sbzyw35jee"
  item    = "OPNsense"
}
