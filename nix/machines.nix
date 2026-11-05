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
      {
        name = "desktop";
        settings = {
          autologinUser = "vuxna";
          bigscreen = true;
        };
      }
      {
        name = "android";
        settings.kioskUser = "vuxna";
      }
      {
        name = "home-player";
        settings.kioskUser = "vuxna";
      }
      {
        name = "staged-updates";
        settings = {
          kioskUser = "vuxna";
          cacheUrl = "http://nixhost.edholm.cc:8080";
          # The public half of the key CI signs with; htpc-stage pins it by
          # value, not by name.
          signingPublicKey = "nixhost-htpc-1:vTlUCuXrl6mPfFwnc0yLnVKDXaL509HLl6iDf9lr+Nk=";
          # Nightly build 01:30, the box wakes at 03:30. Unattended updates
          # land here and nowhere else; `just deploy` ignores it.
          activationWindow = {
            start = "03:30";
            end = "05:30";
          };
        };
      }
    ];
  };
}
