# Evaluation-only checks on the HTPC's assembled configuration: facts that no
# VM test boots but that must hold together -- Home Player is on, it reads its
# secrets from the file `just secrets` installs, and only the grown-up's
# account runs the kiosk. Any false value throws, naming the claim.
{ pkgs, config }:
let
  hm = config.home-manager.users;
  claims = {
    "the backend is enabled" = config.services.home-player.enable;
    "the backend reads secrets from /var/lib/home-player-secrets/env" =
      toString config.services.home-player.environmentFile == "/var/lib/home-player-secrets/env";
    "Wake-on-LAN is armed" = config.services.home-player.wakeOnLan.enable;
    "Android runs for vuxna" = config.roles.android.kioskUser == "vuxna";
    "the update watchdog checks vuxna's kiosk" = config.roles.staged-updates.kioskUser == "vuxna";
    "a rollback is triggered by an unhealthy backend" = config.roles.staged-updates.requireHealthy;
    "vuxna has the kiosk shell" = hm ? vuxna && hm.vuxna.systemd.user.services ? home-player-shell;
    "barn has no kiosk shell" = !(hm ? barn);
    "Android only starts for vuxna" =
      config.systemd.user.services.waydroid-session.unitConfig.ConditionUser or null == "vuxna";
  };
  failed = builtins.attrNames (pkgs.lib.filterAttrs (_: ok: ok != true) claims);
in
assert pkgs.lib.assertMsg (
  failed == [ ]
) "htpc-eval: false: ${builtins.concatStringsSep "; " failed}";
pkgs.runCommand "htpc-eval" { } "touch $out"
