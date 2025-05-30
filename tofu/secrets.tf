# Taken from https://github.com/1Password/terraform-provider-onepassword/issues/117#issuecomment-2135001654
data onepassword_vault ops {
  uuid = "f4h63aecdn7rpzx4sbzyw35jee"
}
data onepassword_item service {
  vault = split("/", data.onepassword_vault.ops.id)[1]
  title = "Proxmox"
}

locals {
  excluded_keys = ["section", "id", "vault", "category"]

  # Get all non-empty top-level fields
  top_level_fields = {
    for key, value in data.onepassword_item.service :
      key => value
    if !contains(local.excluded_keys, key) &&
       value != null &&
       value != "" &&
       !(try(length(value), -1) == 0)  # Exclude empty lists
  }

  # Section fields - also filter out empty values here
  section_fields = merge([
    for section in try(data.onepassword_item.service.section, []) : {
      for field in section.field :
        field.label => field.value
      if field.value != null && field.value != ""
    }
  ]...)

  # Merge both
  proxmox_secrets = merge(
    local.top_level_fields,
    local.section_fields
  )
}
