# The apps a person opens on this box, from Plasma or from Home Player's Apps
# row. Home Player itself carries its own packages; the kiosk account's
# Waydroid apps are the android role's business. Anything a person launches
# belongs here, and the machine's general tools (git, htop, ...) are base's.
{
  lib,
  pkgs,
  ...
}:
{
  # A predicate naming the one package, not a blanket allowUnfree, so an
  # accidental unfree dependency somewhere else still fails loudly. The same
  # policy as nix/roles/dev.nix's claude-code.
  nixpkgs.config.allowUnfreePredicate =
    p:
    builtins.elem (lib.getName p) [
      "discord"
      # The wrapper above is built from this, under the same licence.
      "discord-unwrapped"
    ];

  # On the TV's homescreen among Apps, as well as on Plasma's desktop. A tool
  # only for the desktop goes in environment.systemPackages instead.
  roles.home-player.tvApps = [ pkgs.discord ];
}
