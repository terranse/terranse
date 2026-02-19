# Ansible inventory entries for gaming VMs

resource "ansible_host" "gaming_vm_hosts" {
  for_each = var.configuration

  name   = join(".", [each.key, var.domain])
  groups = [var.host, "gaming_vms"]

  variables = {
    host              = jsonencode(var.host)
    vmid              = jsonencode(local.vmid_map[each.key])
    gpu_type          = jsonencode(each.value.gpu_type)
    vgpu_profile      = jsonencode(each.value.vgpu_profile)
    sriov_vf_index    = jsonencode(each.value.sriov_vf_index)
    physical_display  = jsonencode(each.value.physical_display)
    sunshine_enabled  = jsonencode(each.value.sunshine_enabled)
    steam_enabled     = jsonencode(each.value.steam_enabled)
    retroarch_enabled = jsonencode(each.value.retroarch_enabled)
    snapshot_on_boot  = jsonencode(each.value.snapshot_on_boot)
    roles             = jsonencode(each.value.roles)
  }
}

# Generate Ansible playbook for gaming VMs
resource "local_file" "gaming_playbook" {
  count = length(var.configuration) > 0 ? 1 : 0

  filename = "${var.ansible_root}/playbooks/gaming.yaml"
  content  = yamlencode([
    for name, config in var.configuration : {
      name  = "Configure gaming VM: ${name}"
      hosts = "${name}.${var.domain}"
      roles = concat(
        [{ role = "gaming" }],
        [for r in config.roles : { role = r.name, vars = r.vars }]
      )
      vars = {
        gpu_type          = config.gpu_type
        vgpu_profile      = config.vgpu_profile
        sunshine_enabled  = config.sunshine_enabled
        steam_enabled     = config.steam_enabled
        retroarch_enabled = config.retroarch_enabled
        snapshot_on_boot  = config.snapshot_on_boot
      }
    }
  ])
}
