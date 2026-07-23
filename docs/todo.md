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
- [ ] Add Yale lock — hub is NOT currently on the LAN (power it up first!). Then:
      read labels on hub + in-lock module (Smart Hub vs Connect Bridge; V2N/Classic/L3),
      pick `yale_smart_alarm` or `yale` integration accordingly — both need a Yale
      account (no local path for the Ethernet hub). Alternative: Z-Wave module +
      S2 inclusion (network keys already seeded from 1Password).
- [ ] Matter enablement: flash SkyConnect/ZBT-1 from Zigbee NCP 7.5.1.0 to
      OpenThread RCP, add `otbr` + `matter-server` compose services (+ HA
      Thread/Matter integrations); bulbs are on hand. Mind IPv6/sysctls in the LXC.
- [ ] Fix `proxmox-container` template-download provisioner: only fires on
      resource creation, not template-version bumps (bit us once; manual pveam
      download was needed)
- [ ] ansible-lint root-detection quirk: repo-wide run with
      `-c tests/static/.ansible-lint` reports "0 files processed"; works with
      explicit paths
- [ ] Normalize commit trailer casing (`Co-authored-by:` vs `Co-Authored-By:`)

## Ansible

- [ ] Fix auto creation of `appdata` location for each service; tricky part is to know what bounds a service, e.g. from a Dockerfile, and name it properly
- [ ] Ansible supported Rev proxy groups

## Tofu

- [ ] Move all container/vm declarations to separate vars file
- [ ] Allow VMs to be declared
- [ ] Auto apply Ansible role corresponding to hostname

## Authentication/accesses

- [ ] Configure ACLs to work in conjunction with LDAP/OIDC auth?

