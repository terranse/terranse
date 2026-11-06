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
      # Read from the real box. By id, so the install can only ever write to
      # this disk, whatever order the kernel finds disks in.
      device = "/dev/disk/by-id/nvme-SK_hynix_BC511_HFM256GDJTNI-82A0A_CY05N062410305M16";
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
          luks = {
            size = "100%";
            content = {
              type = "luks";
              name = "cryptroot";
              # Read only while formatting: nixos-anywhere uploads the recovery
              # passphrase here. Nothing in the installed system refers to it.
              passwordFile = "/tmp/htpc-luks.key";
              settings = {
                # The pool's autotrim only reaches the disk if LUKS passes it on.
                allowDiscards = true;
                crypttabExtraOpts = [
                  # Until a slot is enrolled, by hand after Secure Boot is on,
                  # there is no token to find and systemd-cryptsetup moves on
                  # to the passphrase prompt. The same goes when the TPM
                  # refuses, which is what keeps the passphrase a way in.
                  "tpm2-device=auto"
                  # Extends PCR 15 on every unlock. The TPM slot is sealed to PCR
                  # 15 being zero, so once any volume has been opened, a
                  # swapped-in root included, the real key cannot be unsealed.
                  "tpm2-measure-pcr=yes"
                  # Keep asking. Three typos over SSH would otherwise fail the
                  # boot on a box nobody can reach.
                  "tries=0"
                ];
              };
              content = {
                type = "zfs";
                pool = "rpool";
              };
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
