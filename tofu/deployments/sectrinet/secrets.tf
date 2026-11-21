module "proxmox_secrets" {
  source = "../../modules/secrets/1password/"

  providers = {
    onepassword = onepassword
  }

  # One Proxmox API per deployment: currently the home NAS, shared with edholm.
  # A rebuilt jupiter needs its own login back here (account "Our Family",
  # vault baozswa7ic2qo6pzytnuwiqmly, item "Proxmox Patrik") or a second provider.
  account = "NYDLBZ4TCZARLJQURRIVNK3RZM"
  vault   = "f4h63aecdn7rpzx4sbzyw35jee"
  item    = "Proxmox"
}

# NOTE: Per-VM admin credentials are intentionally NOT fetched from 1Password
# here. Telmate's proxmox provider does not yet expose write-only attributes
# for cipassword, so any secret passed through the module would land in the
# tfstate. Instead, admin credentials are baked into each Packer template at
# build time (see winrm_password / preseed user) and rotated by rebuilding.
