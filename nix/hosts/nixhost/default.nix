# The HTPC's build and update host: an LXC, so no hardware.nix or disko.nix.
# What it runs is roles.update-host, switched on in nix/machines.nix.
{ inputs, ... }:
{
  # Stable template filename, as for herdr: tofu's `ostemplate` names it.
  image.baseName = "nixos-lxc-nixhost";

  # The rescue image Pixiecore hands the HTPC, from this same flake.
  roles.update-host.netbootImage = inputs.self.packages.x86_64-linux.htpc-netboot;

  # Per-host: which release this machine's state was created under. Confirm
  # against `nixos-version` on first boot.
  system.stateVersion = "26.11";
}
