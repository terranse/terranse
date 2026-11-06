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
- [x] Add Yale lock — done via the **Verisure** integration (the receiver is a
      Verisure VBox Micro; `lock.ytterdorr` + alarm panel in HA). Caveats: PIN
      management stays in the Verisure app (API doesn't expose it); sessions may
      demand a re-MFA every few days (fallback: `my_verisure` community
      integration); cloud-polling — do NOT firewall-block Verisure or control
      dies (the VBox Micro has no GSM; the lock itself keeps working locally).
      Future option: Z-Wave module + S2 inclusion (keys seeded) for local-only.
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

### HTPC (NixOS)

- [x] Installed 2026-11-06 from nixhost's netboot: ZFS in LUKS, TPM unlock
      (PCR 7+15) proven over two unattended reboots, nightly builds signed and
      published by `nixhost`, update and night-wake timers on.
- [ ] Secure Boot is off. `hp-bioscfg` reads the firmware but every write
      fails (`Returned error 0x4, "Invalid command type"`, no BIOS password
      set), so it needs F10 at the TV: clear the Secure Boot keys, then
      `sudo sbctl enroll-keys --microsoft` (the keys already exist), turn
      Secure Boot on, give the recovery passphrase once, and re-enrol the TPM
      (PCR 7 changes).
- [ ] F10 > Advanced > Power-On Options > After Power Loss: Power On (same
      firmware-write problem).
- [ ] /dev/kvm for nixhost so the nightly gate runs the VM tests: needs a
      terranse path for `provision = "none"` containers; the existing
      vagrant-runner task also sets /dev/kvm to 0666 on the node.
- [ ] Narrower signing on nixhost (`nix copy` with `?secret-key=` in ship.sh)
      so the `nightly` user need not be a nix trusted user.
- [ ] Acceptance on the TV (plan Task 13). herdr's `~/pxe-spike` is gone.
- [ ] Always-on game list: while gaming VM 111 is off (the A5000 slice is
      with ai-vm 114), `gaming.edholm.cc` does not resolve and a box that has
      never polled game-sync shows no games. Serve the library from something
      that never sleeps, so the games are always listed and Play wakes the VM
      (`gpu gaming`, about 30 s) behind a "waking the gaming PC" state.
- [ ] Boot fallback proof (plan Task 14 step 4): deploy a generation that
      panics in the initrd, with a screen on, and see three tries, then the
      previous generation, TPM unlock and an alert.
- [ ] WebKit still holds ~1.1 GB of GPU memory on the homescreen with sized
      art and compositing on; look at which layers are composited if the
      pointer still stutters.

## Ansible

- [ ] Fix auto creation of `appdata` location for each service; tricky part is to know what bounds a service, e.g. from a Dockerfile, and name it properly
- [ ] Ansible supported Rev proxy groups

## Tofu

- [ ] Move all container/vm declarations to separate vars file
- [ ] Allow VMs to be declared
- [ ] Auto apply Ansible role corresponding to hostname

## Authentication/accesses

- [ ] Configure ACLs to work in conjunction with LDAP/OIDC auth?

