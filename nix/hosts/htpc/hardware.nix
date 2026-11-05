# What is true of this box's hardware and nothing else's. Hand-written rather
# than generated: with disko owning the filesystems, everything
# nixos-generate-config would have produced beyond them is this short.
{ lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    "nvme"
    "usb_storage"
    "usbhid"
    "sd_mod"
    # The I219-LM, for SSH before the disk is unlocked.
    "e1000e"
  ];
  boot.kernelModules = [ "kvm-intel" ];

  hardware.cpu.intel.updateMicrocode = lib.mkDefault true;

  # ZFS refuses to import a pool last touched by a different host unless it is
  # forced, and it identifies a host by this. Fixed rather than random so the
  # installer ISO and the installed system agree and no import is ever forced.
  networking.hostId = "8f3a1c2d";
  boot.supportedFilesystems.zfs = true;

  # ZFS is an out-of-tree module, so it pins the kernel. Staying on the LTS
  # default is what keeps a nixpkgs bump from failing to build; nixpkgs' own
  # assertion catches the case where it would.
  services.zfs.autoScrub.enable = true;
  services.zfs.trim.enable = true;

  # Only `home` and `var` hold anything a generation cannot rebuild. The months
  # and years are spelled out as zero because sanoid's defaults keep six months.
  services.sanoid = {
    enable = true;
    datasets =
      lib.genAttrs
        [
          "rpool/home"
          "rpool/var"
        ]
        (_: {
          autosnap = true;
          autoprune = true;
          hourly = 24;
          daily = 7;
          monthly = 0;
          yearly = 0;
        });
  };

  # 8 GB of RAM has Plasma, Android and video to run, and ZFS's cache would
  # otherwise compete with them for it.
  boot.kernelParams = [ "zfs.zfs_arc_max=1073741824" ];
  zramSwap.enable = true;
}
