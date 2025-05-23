# data "onepassword_item" "proxmox_auth" {
#   vault = "f4h63aecdn7rpzx4sbzyw35jee" # HomeNetwork Vault
#   title = "Proxmox"
# }

# Taken from https://github.com/1Password/terraform-provider-onepassword/issues/117#issuecomment-2135001654
data onepassword_vault ops {
  uuid = "f4h63aecdn7rpzx4sbzyw35jee"
}
data onepassword_item service {
  vault = split("/", data.onepassword_vault.ops.id)[1]
  title = "Proxmox"
}
locals {
  proxmox = {for k1, v1 in data.onepassword_item.service.section : v1.label =>  {for k2, v2 in v1.field : v2.label => v2.value}}
}

# locals {
#   op_terraform_fields = { for f in data.onepassword_item.proxmox_auth.section[0].field: f.label => {
#     id = f.id
#     purpose = f.purpose
#     type = f.type
#     value = f.value
#   }
#   }
# }
