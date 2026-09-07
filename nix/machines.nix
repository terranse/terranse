# The single pane: which machine runs which roles. `{ name, settings }`
# mirrors tfvars' `roles = [{ name, vars }]` on purpose -- one shape to learn
# for the whole fleet.
#
# `kind` picks a profile from nix/profiles: whether this machine has firmware
# and a disk ("metal") or is a Proxmox container ("lxc"). It defaults to
# "metal".
#
# `base` is implicit and is never listed.
{
  herdr = {
    system = "x86_64-linux";
    kind = "lxc";
    roles = [ { name = "dev"; } ];
  };

  htpc = {
    system = "x86_64-linux";
    # metal, so the machine gets disko, systemd-boot and EFI variable access
    # from nix/profiles/metal.nix. An LXC gets none of those and needs no
    # disko.nix or hardware.nix at all.
    kind = "metal";
    roles = [ ];
  };
}
