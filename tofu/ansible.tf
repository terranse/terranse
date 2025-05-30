locals {
  # Map module names to actual module references
  all_plays = concat(
    try(module.proxmox-lxc.ansible_plays, []),
    # Add new modules here
  )
}

resource "local_file" "ansible_playbook" {
  filename = "${path.root}/../ansible/playbook.yaml"
  content  = yamlencode(local.all_plays)
}
