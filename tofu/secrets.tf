module "proxmox_secrets" {
  source  = "./modules/secrets/1password/"

  account = "NYDLBZ4TCZARLJQURRIVNK3RZM"
  vault = "f4h63aecdn7rpzx4sbzyw35jee"
  item = "Proxmox"
}
