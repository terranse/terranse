# A rescue image, not an installer. Its whole job is to get the box onto the
# network with sshd and the fleet key so `nixos-anywhere` can take over from
# the laptop -- which is where the private home-player input resolves, so no
# credential is ever written to removable media.
{
  lib,
  modulesPath,
  pkgs,
  ...
}:
{
  imports = [ (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix") ];

  networking.hostName = "htpc-installer";
  # Same id as the installed system, so importing rpool never has to be forced.
  networking.hostId = "8f3a1c2d";

  # The ISO must be able to create the pool nix/hosts/htpc/disko.nix declares.
  # If this ever fails to build, it is ZFS lagging the ISO's kernel: pin
  # `boot.kernelPackages = pkgs.linuxPackages;` (the LTS series) here.
  boot.supportedFilesystems.zfs = lib.mkForce true;

  # mkForce because the installation-device profile already sets this to "yes";
  # a key is on the image, a password is not.
  services.openssh.settings.PermitRootLogin = lib.mkForce "prohibit-password";
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEkdwh5G9JuqNpThbxYqP7RBT9CQJ1fkFeOGuP1sUrXK"
  ];

  # Enough to identify the disk and the NIC without carrying a laptop to the TV.
  environment.systemPackages = with pkgs; [
    ethtool
    gptfdisk
    pciutils
    usbutils
  ];

  # isoImage.isoName is aliased to image.fileName upstream, but the ISO
  # derivation itself is actually named from image.baseName (the
  # isoImage.isoBaseName alias) -- setting isoName alone silently leaves the
  # built file as nixos-minimal-<version>-x86_64-linux.iso. Set both so the
  # file on disk matches what the brief and Step 4's `dd` command expect.
  isoImage.isoBaseName = lib.mkForce "terranse-installer";
  isoImage.isoName = lib.mkForce "terranse-installer.iso";
}
