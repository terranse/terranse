# The disk, declared rather than discovered. disko turns this into both the
# partitioning script the installer runs and the `fileSystems` entries the
# system boots with, so there is exactly one description of the layout and no
# generated file to copy off the box and keep in sync.
#
# Reachable only because nix/machines.nix says kind = "metal"; the disko
# module itself comes from nix/profiles/metal.nix.
{
  disko.devices = {
    disk.main = {
      type = "disk";
      # Confirmed against the real box in Task 3 Step 4 before anything is
      # written. If the box names its disk differently, this line is the only
      # thing that changes.
      device = "/dev/nvme0n1";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              # systemd-boot refuses an ESP that is world-readable.
              mountOptions = [ "umask=0077" ];
            };
          };
          zfs = {
            size = "100%";
            content = {
              type = "zfs";
              pool = "rpool";
            };
          };
        };
      };
    };

    zpool.rpool = {
      type = "zpool";
      options = {
        ashift = "12";
        autotrim = "on";
      };
      rootFsOptions = {
        compression = "zstd";
        # posixacl + xattr=sa are what systemd-journald wants; without them it
        # logs a warning on every boot and ACLs silently do not work.
        acltype = "posixacl";
        xattr = "sa";
        "com.sun:auto-snapshot" = "false";
        mountpoint = "none";
      };

      # Separate datasets so /nix can drop atime and so a future snapshot
      # policy can treat state differently from the store.
      datasets = {
        root = {
          type = "zfs_fs";
          mountpoint = "/";
          options.mountpoint = "legacy";
        };
        nix = {
          type = "zfs_fs";
          mountpoint = "/nix";
          options = {
            mountpoint = "legacy";
            atime = "off";
          };
        };
        var = {
          type = "zfs_fs";
          mountpoint = "/var";
          options.mountpoint = "legacy";
        };
        home = {
          type = "zfs_fs";
          mountpoint = "/home";
          options.mountpoint = "legacy";
        };
      };
    };
  };
}
