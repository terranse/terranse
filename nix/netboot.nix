# The rescue image nixhost netboots to the HTPC's MAC: nix/rescue.nix in RAM,
# with no disk and no ISO. Built from this flake, so it and the installed
# system share one flake.lock. Proven on the box from herdr's ~/pxe-spike.
{
  config,
  modulesPath,
  pkgs,
  ...
}:
let
  build = config.system.build;
in
{
  imports = [
    (modulesPath + "/installer/netboot/netboot-minimal.nix")
    ./rescue.nix
  ];

  # What nixhost's Pixiecore API serves, under the three names it reads. The
  # cmdline is the one upstream's own iPXE script boots with.
  system.build.pixiecoreDir = pkgs.linkFarm "htpc-netboot" [
    {
      name = "bzImage";
      path = "${build.kernel}/${config.system.boot.loader.kernelFile}";
    }
    {
      name = "initrd";
      path = "${build.netbootRamdisk}/initrd";
    }
    {
      name = "cmdline";
      path = pkgs.writeText "htpc-netboot-cmdline" "init=${build.toplevel}/init ${toString config.boot.kernelParams}\n";
    }
  ];
}
