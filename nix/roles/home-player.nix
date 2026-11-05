# The backend as a system service, and the TV shell as a user service for the
# account the desktop role logs in, which the update watchdog can then ask about.
{
  config,
  lib,
  inputs,
  ...
}:
let
  cfg = config.roles.home-player;
in
{
  imports = [
    inputs.home-player.nixosModules.default
    inputs.home-manager.nixosModules.home-manager
  ];

  options.roles.home-player = {
    enable = lib.mkEnableOption "Home Player";

    user = lib.mkOption {
      type = lib.types.str;
      default = config.roles.desktop.user;
      defaultText = lib.literalExpression "config.roles.desktop.user";
      description = "Account the TV shell runs under.";
    };

    secretsFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/home-player-secrets/env";
      description = ''
        KEY=value file with the API keys, placed by `just secrets`. A string so
        that the path is never copied into the Nix store.
      '';
    };

    backendSettings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = ''
        Backend config. Secrets go in as `''${env:NAME}` references, as this
        ends up in the Nix store.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.home-player = {
      enable = true;
      # Without a file the backend fails loudly, rather than start with no keys
      # and fail later on the TV.
      environmentFile = cfg.secretsFile;
      # No authentication on any route, so loopback only.
      settings = lib.recursiveUpdate {
        backend = {
          host = "127.0.0.1";
          port = 9600;
        };
      } cfg.backendSettings;
    };

    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      users.${cfg.user} = {
        imports = [ inputs.home-player.homeModules.default ];
        home.stateVersion = config.system.stateVersion;
        services.home-player-shell = {
          enable = true;
          configureKde = true;
        };
      };
    };
  };
}
