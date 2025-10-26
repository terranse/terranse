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

  # Extract short names from play hosts for inventory lookup
  missing_inventory = {
    for play_name, play in local.all_ansible_plays : 
    play_name => play.hosts
    if !contains(keys(local.all_ansible_inventory), replace(play.hosts, ".${var.domain}", ""))
  }
}

resource "local_file" "ansible_playbook" {
  filename = "${path.root}/../ansible/playbook.yaml"
  content  = yamlencode(local.all_plays_list)
}

resource "ansible_playbook" "run_playbook" {
  for_each = local.all_ansible_plays

  playbook   = local_file.ansible_playbook.filename
  name       = each.value.name
  replayable = true

  lifecycle {
    # Replace when the underlying infrastructure or configuration changes
    # replace_triggered_by = [
    #   terraform_data.host_state[each.key]
    # ]
    precondition {
      condition = length(local.missing_inventory) == 0
      error_message = "Missing inventory entries for plays: ${jsonencode(local.missing_inventory)}"
    }
  }

  verbosity = 2  # Adjust as needed (0-4)

  depends_on = [
    local_file.ansible_playbook,
    module.proxmox-lxc
    # Add new modules here!
  ]

  # Pass variables from the play configuration
  extra_vars = merge(
    try(each.value.vars, {}),
    {
      # Add some debugging info
      terraform_play_name = each.key
      terraform_host_name = local.play_to_host[each.key]
    }
  )
}

# Debug output
output "ansible_debug" {
  value = var.debug_ansible ? {
    total_plays = length(local.all_ansible_plays)
    total_hosts = length(local.all_ansible_inventory)
    plays = local.all_ansible_plays
    inventory = local.all_ansible_inventory
  } : null
}

variable "debug_ansible" {
  description = "Enable ansible debugging outputs"
  type        = bool
  default     = false
}
