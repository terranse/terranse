# What to work on and in what order

## Services
### Nextcloud
 - [ ] Fix first init of container to recognize DB options
 - [ ] Add service for exposing dir, e.g. `cloud`, as S3 bucket
 - [ ] Automatic connection to auth server

### Starr
 - [ ] Align folder structure to to allow hard links/atomic moves
 - [ ] Copy data to working drives
 - [ ] Make sure to extract broken files and deal with those

### OpnSense
 - [ ] Install to server!
 - [ ] Configure according to: https://forum.opnsense.org/index.php?topic=23339.0
   - [ ] Reverse proxy
   - [ ] Wildcard lets encrypt cert

### HomeAssistant
- [ ] Install!
- [ ] Forward USB HW
- [ ] Add Yale + existing lights

## Ansible
 - [ ] Create new backup solution based on Borg!
- [ ] Fix auto creation of `appdata` location for each service; tricky part is to know what bounds a service, e.g. from a Dockerfile, and name it properly
 - [ ] Ansible supported Rev proxy groups

## Terraform
 - [ ] Move all container/vm declarations to separate vars file
 - [ ] Allow VMs to be declared
 - [ ] Cloud init to images, e.g., via Packer
 - [ ] Auto apply Ansible role corresponding to hostname

## Authentication/accesses
 - [ ] Remove guest SMB access from ZFS
 - [ ] Configure ACLs to work in conjunction with LDAP/OIDC auth?

## Future
Create distributed way of having many things running reliably.