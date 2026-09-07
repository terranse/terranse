# A machine with real firmware and a real disk -- bare metal or a full VM.
#
# These settings used to live in nix/roles/base.nix. They moved out the day the
# fleet gained its first container: `boot.loader.systemd-boot` and the LXC's
# `boot.loader.initScript` both define `system.build.installBootLoader`, which
# is a plain option with no merge function, so a container importing them would
# fail to evaluate with a definition conflict.
{ inputs, ... }:
{
  # Declarative partitioning. Only a machine that owns a disk needs it.
  imports = [ inputs.disko.nixosModules.disko ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
}
