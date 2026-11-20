# The apps a person opens from Plasma on this box. Home Player is the TV's
# homescreen and carries its own packages; the kiosk account's Waydroid apps
# are the android role's business. Anything a person launches from the desktop
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

  environment.systemPackages = [ pkgs.discord ];
}
