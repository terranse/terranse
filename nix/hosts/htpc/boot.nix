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
