locals {
  # Collect all plays from all module types in one place
  all_plays_list = concat(
    flatten([
      for instance in module.proxmox-lxc : instance.ansible_plays
    ]),

    # Add other module types here, e.g.:
    # flatten([
    #   for instance in module.proxmox-vm : instance.ansible_plays
    # ]),
  )

  # Same pattern for inventory
  all_ansible_inventory = merge(
    merge([
      for instance in module.proxmox-lxc : instance.ansible_inventory
    ]...),

    # Add other module types here, e.g.:
    # merge([
    #   for instance in module.proxmox-vm : instance.ansible_inventory
    # ]...),
  )

  # Create play map indexed by play name
  all_ansible_plays = { for play in local.all_plays_list : play.name => play }

  # Create a mapping from play name to host name for easier lookup
  play_to_host = { for play in local.all_plays_list : play.name => play.hosts }
}

resource "local_file" "ansible_playbook" {
  filename = "${path.root}/../ansible/playbook.yaml"
  content  = yamlencode(local.all_plays_list)
}

# Tracks the state of ansible hosts to avoid unnecessary runs by recording
# a hash of the current configuration (roles, services, docker_services).
# Changes are detected by comparing input vs output in the next resource.
resource "terraform_data" "host_state" {
  for_each = local.all_ansible_plays

  input = {
    # Get the actual host name from the play
    host_name           = local.play_to_host[each.key]
    roles               = sha256(jsonencode(each.value.roles))
    roles_len           = length(each.value.roles)
    # Access inventory using the hostname
    services            = sha256(jsonencode(try(local.all_ansible_inventory[local.play_to_host[each.key]].services, [])))
    services_len        = length(try(local.all_ansible_inventory[local.play_to_host[each.key]].services, []))
    docker_services     = sha256(jsonencode(try(local.all_ansible_inventory[local.play_to_host[each.key]].docker_services, [])))
    docker_services_len = length(try(local.all_ansible_inventory[local.play_to_host[each.key]].docker_services, []))
  }
}

# Determines if a host needs recreation based on configuration changes.
# If items are only added (length increased), no recreation is needed.
# If items are removed or changed (same/decreased length but different content),
# the host is recreated since there's no uninstall mechanism in Ansible.
# TODO: This part did not work as intended, so it's commented out for now.
# resource "terraform_data" "trigger_recreate" {
#   triggers_replace = {
#     for k, v in local.all_ansible_plays : k => (
#       (
#         # If any config has grown, don't trigger recreation (just additions)
#         terraform_data.host_state[k].input.roles_len > try(terraform_data.host_state[k].output.roles_len, 0) ||
#         terraform_data.host_state[k].input.services_len > try(terraform_data.host_state[k].output.services_len, 0) ||
#         terraform_data.host_state[k].input.docker_services_len > try(terraform_data.host_state[k].output.docker_services_len, 0)
#       ) ? false : (
#         # If length stayed same/decreased, check if content changed
#         terraform_data.host_state[k].input.roles != try(terraform_data.host_state[k].output.roles, "") ||
#         terraform_data.host_state[k].input.services != try(terraform_data.host_state[k].output.services, "") ||
#         terraform_data.host_state[k].input.docker_services != try(terraform_data.host_state[k].output.docker_services, "")
#       )
#     )
#   }
# }

resource "ansible_playbook" "run_playbook" {
  for_each = local.all_ansible_plays

  playbook   = local_file.ansible_playbook.filename
  name       = each.value.name
  replayable = true

  lifecycle {
    # Replace when the underlying infrastructure or configuration changes
    replace_triggered_by = [
      terraform_data.host_state[each.key]
    ]
  }

  depends_on = [
    local_file.ansible_playbook,
    module.proxmox-lxc
    # Add new modules here!
  ]

  # Pass variables from the play configuration
  extra_vars = try(each.value.vars, {})
}
