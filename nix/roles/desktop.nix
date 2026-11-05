# Plasma, logged in by itself. Home Player runs fullscreen on top of it, so a
# real desktop and Android stay running behind the TV interface and leaving for
# either is instant.
{
  config,
  lib,
  ...
}:
let
  cfg = config.roles.desktop;
in
{
  options.roles.desktop = {
    enable = lib.mkEnableOption "the Plasma session behind Home Player";

    user = lib.mkOption {
      type = lib.types.str;
      default = "vuxna";
      description = "Account logged in automatically at boot.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      isNormalUser = true;
      description = "Vuxna";
      # Not wheel: base.nix makes wheel passwordless, and this session is logged
      # in with nobody at the keyboard. `input` is for the remote's keys that
      # the shell reads past the compositor.
      extraGroups = [
        "audio"
        "input"
        "render"
        "video"
      ];
    };

    services.desktopManager.plasma6.enable = true;
    services.displayManager = {
      sddm = {
        enable = true;
        wayland.enable = true;
      };
      autoLogin = {
        enable = true;
        inherit (cfg) user;
      };
      defaultSession = "plasma";
    };

    # Autologin has no password to open a wallet with, so it would only prompt.
    security.pam.services.sddm.kwallet.enable = lib.mkForce false;
    security.pam.services.login.kwallet.enable = lib.mkForce false;
  };
}
