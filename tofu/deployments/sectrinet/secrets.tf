module "proxmox_secrets" {
  source = "../../modules/secrets/1password/"

  providers = {
    onepassword = onepassword
  }

  account = "Our Family"
  vault   = "baozswa7ic2qo6pzytnuwiqmly" # Update if "Proxmox Patrik" is in a different vault
  item    = "Proxmox Patrik"
}

# NOTE: Per-VM admin credentials are intentionally NOT fetched from 1Password
# here. Telmate's proxmox provider does not yet expose write-only attributes
# for cipassword, so any secret passed through the module would land in the
# tfstate. Instead, admin credentials are baked into each Packer template at
# build time (see winrm_password / preseed user) and rotated by rebuilding.
