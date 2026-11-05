# Plasma on Wayland with a login screen that is skipped for one account. The
# TV boots straight into that account's session; the other account signs in
# from SDDM.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.roles.desktop;
in
{
  options.roles.desktop = {
    enable = lib.mkEnableOption "Plasma on Wayland with an automatic login";

    autologinUser = lib.mkOption {
      type = lib.types.str;
      description = "Account the machine signs in to on boot.";
    };

    bigscreen = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Also install Plasma Bigscreen, a session made for a TV.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.displayManager = {
      sddm = {
        enable = true;
        wayland.enable = true;
      };
      autoLogin = {
        enable = true;
        user = cfg.autologinUser;
      };
    }
    // lib.optionalAttrs cfg.bigscreen {
      # Listed explicitly: the package is only a session if the display
      # manager is told to look inside it.
      sessionPackages = [ pkgs.kdePackages.plasma-bigscreen ];
    };

    services.desktopManager.plasma6.enable = true;

    environment.systemPackages = lib.optional cfg.bigscreen pkgs.kdePackages.plasma-bigscreen;

    # A wallet that asks for a password the TV's users never set would pop up
    # over every app that stores a login. System-wide, so it covers both
    # accounts and any added later.
    environment.etc."xdg/kwalletrc".text = ''
      [Wallet]
      Enabled=false
    '';

    # Part of the system's closure, so building the machine fails if the
    # session file is missing, rather than a TV that boots to a session list
    # without it. A build step and not an evaluation-time check, which would
    # have to build the package just to look inside it.
    system.extraDependencies = lib.optional cfg.bigscreen (
      pkgs.runCommand "plasma-bigscreen-session-check" { } ''
        test -e ${pkgs.kdePackages.plasma-bigscreen}/share/wayland-sessions/plasma-bigscreen-wayland.desktop
        touch $out
      ''
    );
  };
}
