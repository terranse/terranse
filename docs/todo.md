# What to work on and in what order

## Services

### Nextcloud

- [ ] Automatic connection to auth server

### OpnSense

- [ ] Configure according to: <https://forum.opnsense.org/index.php?topic=23339.0>

### HomeAssistant

- [ ] Install!
- [ ] Forward USB HW
- [ ] Add Yale + existing lights

## Ansible

- [ ] Fix auto creation of `appdata` location for each service; tricky part is to know what bounds a service, e.g. from a Dockerfile, and name it properly
- [ ] Ansible supported Rev proxy groups

## Tofu

- [ ] Move all container/vm declarations to separate vars file
- [ ] Allow VMs to be declared
- [ ] Auto apply Ansible role corresponding to hostname

## Authentication/accesses

- [ ] Configure ACLs to work in conjunction with LDAP/OIDC auth?

