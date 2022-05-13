# The general idea of this project
The main goal is to have a fully reprodicible home server build with, more or less, a simple command. E.g.
`make it so`. The setup is meant to use to two components and to the furthest extent possible use very few
dependencies; this is to, hopefully, futureproof the project a bit more. Mainly `ansible` and `terraform`
will be used, where the former finds and sets up all entities created by the latter. 

## How it all connects
ROUGHLY:
### Terraform
Terraform is ran first -- although it is called from Ansible currently -- which will then setup all the
different machines, specified as tf modules, in your `terraform/main.tf`. For each module, it will
automatically call a similarly named (based on the hostname, currently) ansible file under `ansible/roles/`.
This role, in turn, is expected to contain some kind of Docker compose setup, but does not need to.
The modules under `terraform/modules/*` gives the basic building blocks for setting up a new container or
VM. In the future this could probably be expanded with adding support for VPS/cloud modules, and VMs could,
ideally, simply be moved to another provider by changing the `source =` line in the module declaration.

Terraform will output a inventory file for Ansible to use, based on the `inventory.tmpl` file. This file
will be used when generating an inventory file for Ansible to use, and as such keeps your terraform files
as the single source of truth as to what machines exists and how to get to them.
 - TODO: Currently the inventory file is only copied as-is and variables are not substituted. As such,
 Ansible cannot be run separately after Terraform is completed. The inventory is, however, perfectly
 used when calling Ansible from Terraform (I think).
## Setup

### Adding features
When adding new features, machines (VMs/CTs) or modules, remember that the current setup requires that the
module, hostname and the (possibly) correspondning ansible .yaml file is called the same. E.g., you should
have something like:
```HCL
module "media" {
    ...
    hostname = media
}
```
and a file in `ansible/roles/` with the name `media.yaml`.
### Adding mount points
~When adding bind mount points in the `terraform/main.tf` file,~[1] you can add the whole given directory by
setting `size` to 0. This should make the whole given directory accessible from within the container --
but remember that you need to setup permissions and acls before your container is actually allowed to touch
anything. By running `scripts/setup-bind-mount-support.yaml` from within your (new) ansible role, you 
should be able to access everything correctly with new user and group created on the host proxmox system
mapped to the corresponding user and group inside the CT.

I am unsure which is the best option for an ZFS mount in this case; either you use a bind mount or a storage
mount. I think that in the first case, you simply pass on the mounted directory/fs from the host with no
added latency, and in the latter case you pass the ZFS volume instead. This last config option allows you to
interact with ZFS directly inside the container, e.g. taking snapshots and, e.g., uploading those for backup.

[It appears that only root can configure mountpoints, which means that this part will have to be revised and
set up in Ansible instead]
## How to run
Currently the project is setup by running: `ansible-playbook -i inventory deploy_infra.yaml` from the
`infra/ansible` directory. I think the project is currently quite sensitive of where you run from.

## Obstacles


