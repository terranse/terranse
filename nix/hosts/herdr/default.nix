# Everything host-specific, in one import. mkMachine imports this directory,
# so adding a file here needs no change to the flake.
#
# It is the whole host: `kind = "lxc"` means no hardware.nix and no disko.nix.
{
  # Stable template filename. The default is
  # nixos-image-<system.nixos.label>-x86_64-linux.tar.xz, whose label carries
  # the nixpkgs revision -- so the name would change on every flake update and
  # tofu's `ostemplate` string would have to chase it.
  image.baseName = "nixos-lxc-herdr";

  # Per-host, not fleet-wide: a statement about which release this machine's
  # state was created under. Confirm against `nixos-version` on first boot.
  system.stateVersion = "26.11";
}
