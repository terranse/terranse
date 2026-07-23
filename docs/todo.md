# What to work on and in what order

## Services

### Nextcloud

- [ ] Automatic connection to auth server

### OpnSense

- [ ] Configure according to: <https://forum.opnsense.org/index.php?topic=23339.0>

### HomeAssistant

- [x] Install!
- [x] Forward USB HW
- [x] Add existing lights (Hue bridge paired; 28 lights + 31 scenes in HA)
- [ ] Add Yale lock — older Doorman on proprietary Ethernet hub: either create a
      Yale account (Yale Smart Living cloud integration) or fit the Z-Wave module
      and S2-include against the stick (network keys already seeded from 1Password)

## Ansible

- [ ] Fix auto creation of `appdata` location for each service; tricky part is to know what bounds a service, e.g. from a Dockerfile, and name it properly
- [ ] Ansible supported Rev proxy groups

## Tofu

- [ ] Move all container/vm declarations to separate vars file
- [ ] Allow VMs to be declared
- [ ] Auto apply Ansible role corresponding to hostname

## Authentication/accesses

- [ ] Configure ACLs to work in conjunction with LDAP/OIDC auth?

