# A rescue image, not an installer: the ISO form of nix/rescue.nix, for when
# the box cannot netboot from nixhost.
{
  lib,
  modulesPath,
  ...
}:
{
  imports = [
    (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix")
    ./rescue.nix
  ];

  # isoImage.isoName is aliased to image.fileName upstream, but the ISO
  # derivation itself is actually named from image.baseName (the
  # isoImage.isoBaseName alias) -- setting isoName alone silently leaves the
  # built file as nixos-minimal-<version>-x86_64-linux.iso. Set both so the
  # file on disk matches what the brief and Step 4's `dd` command expect.
  isoImage.isoBaseName = lib.mkForce "terranse-installer";
  isoImage.isoName = lib.mkForce "terranse-installer.iso";
}
