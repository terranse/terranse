# Home Player on the TV: the backend as a system service, the kiosk shell as
# one account's user service. Everything the app needs to know about the
# household's other services is written here; every secret is a reference to
# a variable in the file `just secrets htpc` installs.
{
  config,
  lib,
  inputs,
  ...
}:
let
  cfg = config.roles.home-player;

  # Where `just secrets` puts the rendered env file. Not under the kiosk
  # user's home: the backend is a system service and needs no login to start.
  secretsFile = "/var/lib/home-player-secrets/env";
  ref = name: "\${env:${name}}";
in
{
  imports = [
    inputs.home-player.nixosModules.default
    inputs.home-manager.nixosModules.home-manager
  ];

  options.roles.home-player = {
    enable = lib.mkEnableOption "the Home Player backend and kiosk shell";

    kioskUser = lib.mkOption {
      type = lib.types.str;
      description = "Account that runs the kiosk shell. No other account gets it.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.home-player = {
      enable = true;
      environmentFile = secretsFile;
      # The remote and the update watchdog both want the machine to stay
      # reachable for a scheduled wake.
      wakeOnLan.enable = true;

      settings = {
        # Loopback only: the backend has no authentication of its own.
        backend = {
          host = "127.0.0.1";
          port = 9600;
        };

        providers = {
          jellyfin = {
            url = "http://media.edholm.cc:8096";
            api_token = ref "JELLYFIN_API_KEY";
            user_id = "ab08126b51044224a5012d3749122f4f";
          };
          sonarr = {
            url = "http://media.edholm.cc:8989";
            api_token = ref "SONARR_API_KEY";
          };
          radarr = {
            url = "http://media.edholm.cc:7878";
            api_token = ref "RADARR_API_KEY";
          };
          # Requests join the Upcoming rows. Seerr's own key, not Jellyfin's.
          jellyseerr = {
            url = "http://media.edholm.cc:5055";
            api_token = ref "SEERR_API_KEY";
          };
          gamesync.url = "http://gaming.edholm.cc:9766";
        };

        # Pairs a Moonlight client without anyone typing a PIN.
        sunshine = {
          host = "gaming.edholm.cc";
          username = "admin";
          password = ref "SUNSHINE_PASSWORD";
        };

        # No gpu_manager section: its orchestration branch is not merged.
        home_assistant = {
          url = "http://home.edholm.cc:8123";
          token = ref "HA_TOKEN";
          tv = "media_player.android_tv_2";
          receiver = "media_player.marantz_sr6009";
        };
      };
    };

    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      users.${cfg.kioskUser} = {
        imports = [ inputs.home-player.homeModules.default ];
        home.stateVersion = config.system.stateVersion;
        services.home-player-shell = {
          enable = true;
          # The remote's Power and volume keys go to Home Player, not Plasma.
          configureKde = true;
        };
      };
    };

    # The shell reads the remote through /dev/input.
    users.users.${cfg.kioskUser}.extraGroups = [ "input" ];
  };
}
