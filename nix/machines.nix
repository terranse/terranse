# The single pane: which machine runs which roles. `{ name, settings }`
# mirrors tfvars' `roles = [{ name, vars }]` on purpose -- one shape to learn
# for the whole fleet.
#
# `kind` picks a profile from nix/profiles: whether this machine has firmware
# and a disk ("metal") or is a Proxmox container ("lxc"). It defaults to
# "metal".
#
# `base` is implicit and is never listed.
{
  herdr = {
    system = "x86_64-linux";
    kind = "lxc";
    roles = [ { name = "dev"; } ];
  };

  htpc = {
    system = "x86_64-linux";
    # metal, so the machine gets disko, systemd-boot and EFI variable access
    # from nix/profiles/metal.nix. An LXC gets none of those and needs no
    # disko.nix or hardware.nix at all.
    kind = "metal";
    roles = [
      {
        name = "video";
        settings = {
          driver = "intel";
        };
      }
      # home-player and kiosk are not implemented yet (Tasks 7 and 9) -- this
      # role's defaults for healthUrl and kioskUser point at pieces that do
      # not exist on this machine until those land. A failed health check
      # reads as idle, so the update loop still works in the gap.
      {
        name = "staged-updates";
        settings = {
          # home-player is not deployed on this machine yet, so there is no
          # /health to poll. False means the watchdog treats a fresh
          # activation as unverified-but-kept, not as a rollback trigger --
          # the default (true) would roll back every good update and then
          # permanently refuse it via bad-revisions. Flip this back to true
          # (or delete the override) the moment home-player lands.
          requireHealthy = false;
        };
      }
    ];
  };
}
