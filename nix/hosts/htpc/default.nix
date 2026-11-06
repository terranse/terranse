# Everything host-specific, in one import. mkMachine imports this directory,
# so adding a file here needs no change to the flake.
{ config, ... }:
{
  imports = [
    ./hardware.nix
    ./disko.nix
    ./boot.nix
    ./accounts.nix
    ./deploy.nix
    ./living-room.nix
  ];

  # A statement about which release this machine's state was created under,
  # not a version to keep current -- changing it later migrates nothing. It
  # lives here rather than in the shared base role because it is per-machine:
  # a box installed next year says something else, and one fleet-wide value
  # would silently be wrong for the second machine that ever appears.
  system.stateVersion = "26.11";

  # nixhost's cache, as a substituter: `just deploy-nixos htpc` and `just
  # deploy htpc` then fetch what nixhost built instead of compiling it here, and
  # the deploy account can realise a published closure. Its key is already in
  # trusted-public-keys (base.nix), so nothing new is trusted.
  nix.settings.substituters = [ config.roles.staged-updates.cacheUrl ];
}
