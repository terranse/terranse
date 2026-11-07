# How this box gets from firmware to its root filesystem with nobody at it:
# Lanzaboote signs the boot chain, and the initrd brings up SSH so the disk can
# be unlocked from another room until the TPM takes that over.
{
  config,
  inputs,
  lib,
  options,
  pkgs,
  ...
}:
{
  imports = [ inputs.lanzaboote.nixosModules.lanzaboote ];

  # The metal profile enables it for every machine; Lanzaboote replaces it here
  # only, and the two cannot both install a boot loader.
  boot.loader.systemd-boot.enable = lib.mkForce false;

  boot.lanzaboote = {
    enable = true;
    # Where `sbctl create-keys` puts them. sbctl itself is what creates and
    # enrols them, by hand, after first boot.
    pkiBundle = "/var/lib/sbctl";
    # Those keys cannot exist yet when nixos-anywhere installs the boot loader,
    # and without this lzbt fails the install on the missing files. It signs as
    # soon as they are present, and the signed files replace the unsigned ones
    # on the next rebuild because their names depend on the public key.
    allowUnsigned = true;
    # Every generation with a new kernel or initrd costs its size again on the
    # 1 GiB ESP, and a full ESP fails the update. Rollback only needs a few.
    configurationLimit = 5;
    # A new generation gets three tries. A boot that never gets as far as
    # boot-complete.target (below) uses one up; when all three are gone,
    # systemd-boot sorts the entry last and the previous generation boots.
    # A boot that panics or hangs only comes round again because of the
    # panic= parameter and the hardware watchdog below.
    bootCounting.initialTries = 3;
  };

  # A boot counts as good once the box can be reached again: SSH is up. Not
  # multi-user.target: one stuck unit holds that back forever (a oneshot
  # waydroid-store once did), and a box that is reachable can be fixed from
  # another room, while three such boots would roll back a working generation.
  # A boot that gets this far but whose Home Player is unhealthy is the update
  # watchdog's to roll back (staged-updates.nix); tying the backend's health
  # here too would roll the same failure back twice.
  systemd.targets.boot-complete = {
    requires = [ "sshd.service" ];
    after = [ "sshd.service" ];
  };

  # A kernel panic, in the initrd or later, reboots after 10 s instead of
  # sitting on a screen nobody sees, so the next boot can count it.
  boot.kernelParams = [ "panic=10" ];

  # A hang is the hardware watchdog's: systemd pets the chipset's TCO timer,
  # and if it stops for 30 s the board resets itself. The board also has an
  # Intel overclocking watchdog that registers first, and systemd uses the
  # first; it is kept out so the TCO timer is the only one.
  boot.blacklistedKernelModules = [ "intel_oc_wdt" ];
  boot.kernelModules = [ "iTCO_wdt" ];
  systemd.settings.Manager = {
    RuntimeWatchdogSec = "30s";
    # A reboot that itself hangs is cut short too.
    RebootWatchdogSec = "10min";
  };

  environment.systemPackages = [ pkgs.sbctl ];

  # Newer nixpkgs removed the option (the initrd is always systemd there) and
  # throw if it is set; it stays declared but invisible, so test that.
  boot.initrd.systemd.enable = lib.mkIf (options.boot.initrd.systemd.enable.visible or true) true;

  # NixOS orders the root pool's import after nothing to do with LUKS and gives
  # it 60 seconds. On a pool inside LUKS, a person taking longer than that to
  # type the passphrase would fail the boot into an emergency shell nobody can
  # reach, so the import waits for the unlock, however long that takes.
  boot.initrd.systemd.services.zfs-import-rpool.after = [ "cryptsetup.target" ];

  # Left alone, the initrd sends a client ID derived from a machine-id it makes
  # up on each boot, and the installed system sends none. Both send the NIC's
  # MAC instead, so the DHCP server sees one client however the box booted.
  boot.initrd.systemd.network.networks."99-ethernet-default-dhcp".dhcpV4Config.ClientIdentifier =
    "mac";
  networking.dhcpcd.extraConfig = "clientid";

  boot.initrd.network = {
    enable = true;
    ssh = {
      enable = true;
      # Not 22, so the laptop's known_hosts never sees this box offer two keys
      # for one address: this key lives in the clear on the ESP, and the real
      # host key stays on the encrypted disk.
      port = 2222;
      # A string on purpose. A Nix path would be read at evaluation, so building
      # on the laptop would fail or copy the private key into the store. This
      # way the boot loader installer reads it from the box as it writes each
      # initrd, and a missing file fails that install rather than the boot.
      # nixos-anywhere puts it in place as an extra file before installing.
      hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
      authorizedKeys = config.users.users.default-user.openssh.authorizedKeys.keys;
    };
  };
}
