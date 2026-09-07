# An unprivileged Proxmox CT.
#
# proxmox-lxc.nix sets `boot.isContainer`, and nixos/modules/virtualisation/
# container-config.nix keys off exactly that: no kernel, no initrd, no grub, no
# udev -- and, because `boot.initrd.enable` defaults to `!isContainer`, none of
# stage-1's "the fileSystems option does not specify your root file system"
# assertion either. That is why an LXC machine needs neither a disko.nix nor a
# hardware.nix.
#
# The same module also produces `config.system.build.tarball`, the rootfs image
# the flake exports as <machine>-lxc-template -- built from the very same
# toplevel `nixos-rebuild` later deploys, so the template and the running
# system are never two different things.
{ modulesPath, ... }:
{
  imports = [ (modulesPath + "/virtualisation/proxmox-lxc.nix") ];

  proxmoxLXC = {
    # Adds the ping capability wrapper (an unprivileged CT cannot set
    # net.ipv4.ping_group_range) and drops the /sys/kernel/debug mount.
    privileged = false;

    # Proxmox writes /etc/systemd/network/eth0.network from net0, so tofu
    # stays the single source of truth for the MAC and the addressing.
    manageNetwork = false;

    # WITHOUT this the module does `networking.hostName = mkForce ""`, silently
    # discarding the name mkMachine set -- and PVE's NixOS setup plugin's
    # set_hostname() is a deliberate no-op, so nothing would ever write
    # /etc/hostname either.
    manageHostName = true;
  };

  # proxmox-lxc.nix suppresses /sys/kernel/debug; these three it does not, and
  # none of them can succeed in an unprivileged CT.
  systemd.suppressedSystemUnits = [
    "dev-mqueue.mount"
    "sys-kernel-debug.mount"
    "sys-fs-fuse-connections.mount"
  ];

  # networkd hands the DHCP-provided nameservers to resolved. Without it the
  # boot-time `resolvconf -u` has no subscriber and /etc/resolv.conf can come
  # up empty.
  services.resolved.enable = true;
}
