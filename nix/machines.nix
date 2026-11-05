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
      { name = "android"; settings.kioskUser = "vuxna"; }
      { name = "desktop"; }
      {
        name = "home-player";
        settings.backendSettings = {
          providers = {
            jellyfin = {
              url = "http://media.edholm.cc:8096";
              api_token = "\${env:JELLYFIN_API_KEY}";
              user_id = "\${env:JELLYFIN_USER_ID}";
            };
            sonarr = {
              url = "http://media.edholm.cc:8989";
              api_token = "\${env:SONARR_API_KEY}";
            };
            radarr = {
              url = "http://media.edholm.cc:7878";
              api_token = "\${env:RADARR_API_KEY}";
            };
            jellyseerr = {
              url = "http://media.edholm.cc:5055";
              api_token = "\${env:SEERR_API_KEY}";
            };
            gamesync.url = "http://gaming.edholm.cc:9766";
            waydroid.apps = [
              {
                name = "Aurora Store";
                package = "com.aurora.store";
              }
            ];
          };
          sunshine = {
            host = "gaming.edholm.cc";
            username = "\${env:SUNSHINE_USERNAME}";
            password = "\${env:SUNSHINE_PASSWORD}";
          };
        };
      }
      {
        name = "staged-updates";
        settings = {
          kioskUser = "vuxna";
          # The backend fails until `just secrets` has put its keys on the box,
          # and the default (true) would roll back every update until then and
          # permanently refuse each via bad-revisions. Delete this override once
          # the box is up with its keys in place.
          requireHealthy = false;
        };
      }
    ];
  };
}
