# Tells someone when unattended updating stops or goes wrong.
#
# Checked once per night run (htpc-night starts the unit; nothing else does),
# against the state files the update path already keeps. What it says is
# remembered in /var/lib/htpc-update, so a problem is reported once, not every
# night. A failed notification is not remembered, so the next night tries again.
# Nothing here can fail the unit or the run that starts it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.roles.update-alerts;

  stateDir = "/var/lib/htpc-update";
  # Three nights, as Home Player's notice counts them.
  staleSeconds = 259200;

  ha-notify = pkgs.writeShellApplication {
    name = "ha-notify";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      jq
    ];
    text = builtins.readFile ../../scripts/ha-notify.sh;
  };

  htpc-update-alerts = pkgs.writeShellApplication {
    name = "htpc-update-alerts";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      jq
      ha-notify
    ];
    text = ''
      state=${stateDir}/state.json
      sent=${stateDir}/alerts-sent
      stale_flag=${stateDir}/alerts-stale

      check() {
        [ -r "$state" ] || return 0
        touch "$sent"

        # Ask again rather than trust the file: on a night with nothing to
        # fetch, nothing else has looked at the cache since the last run.
        local build_age staged now
        build_age=$(/run/current-system/sw/bin/htpc-build-age) || build_age=null
        staged=$(jq -r '.staged_at // 0' "$state")
        now=$(date -u +%s)
        [[ $staged =~ ^[0-9]+$ ]] || staged=0
        jq --argjson b "$build_age" --argjson staged "$staged" --argjson now "$now" \
          '.build_age_seconds = $b
           | .age_seconds = (if $staged == 0 then 0 else $now - $staged end)' \
          "$state" > "$state.alerts" && mv "$state.alerts" "$state"

        local reason pending rolled stale
        reason=$(jq -r '.reason // ""' "$state")
        pending=$(jq -r '.pending // ""' "$state")
        rolled=$(jq -r '.rolled_back_at // ""' "$state")
        stale=$(jq -r '((.age_seconds // 0) >= ${toString staleSeconds})
                       or ((.build_age_seconds // 0) >= ${toString staleSeconds})' "$state")

        local keys=() lines=()
        add() {
          grep -qxF -- "$1" "$sent" || { keys+=("$1"); lines+=("$2"); }
        }
        if [ -n "$rolled" ]; then
          add "rolled-back:$rolled" "An update was rolled back at $rolled."
        fi
        if [ "$reason" = rollback-failed ]; then
          add "rollback-failed:$pending" "An update failed and could not be rolled back; the box is still on it."
        fi
        local bad
        while read -r bad; do
          [ -z "$bad" ] || add "bad:$bad" "Revision marked bad: $bad"
        done < ${stateDir}/bad-revisions

        local stale_new=0
        if [ "$stale" = true ]; then
          if [ ! -e "$stale_flag" ]; then
            stale_new=1
            lines+=("No update has been built or taken for 3 nights.")
          fi
        else
          rm -f "$stale_flag"
        fi

        [ "''${#lines[@]}" -gt 0 ] || return 0

        local failed message
        failed=$(mktemp)
        rm -f "$failed"
        message=$(printf '%s\n' "''${lines[@]}")
        HA_NOTIFY_FAILED_FLAG=$failed ha-notify "HTPC updates need attention" "$message"
        if [ -e "$failed" ]; then
          rm -f "$failed"
          echo "htpc-update-alerts: not delivered; will try again next time" >&2
          return 0
        fi
        local key
        for key in "''${keys[@]}"; do printf '%s\n' "$key" >> "$sent"; done
        if [ "$stale_new" -eq 1 ]; then touch "$stale_flag"; fi
      }

      # Never the reason a night's run, or an activation, goes wrong.
      check || echo "htpc-update-alerts: the check itself failed" >&2
      exit 0
    '';
  };
in
{
  options.roles.update-alerts = {
    enable = lib.mkEnableOption "phone alerts when unattended updating stops or rolls back";

    notifyService = lib.mkOption {
      type = lib.types.str;
      example = "notify.mobile_app_pixel_8";
      description = "Home Assistant notify service that reaches the phone.";
    };

    haUrl = lib.mkOption {
      type = lib.types.str;
      default = lib.attrByPath [ "services" "home-player" "settings" "home_assistant" "url" ] "" config;
      defaultText = "the Home Assistant URL Home Player is configured with";
      description = "Where Home Assistant is; the same address Home Player uses.";
    };

    environmentFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/home-player-secrets/env";
      description = ''
        File with HA_TOKEN=..., read by systemd and never by this repo. The
        one `just secrets htpc` installs for Home Player.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.roles.staged-updates.enable;
        message = "roles.update-alerts reports on roles.staged-updates, which is not enabled";
      }
      {
        assertion = cfg.haUrl != "";
        message = "roles.update-alerts needs roles.update-alerts.haUrl (no Home Player Home Assistant URL to reuse)";
      }
    ];

    environment.systemPackages = [ ha-notify ];

    systemd.services.htpc-update-alerts = {
      description = "Tell someone when updates stop or roll back";
      # Started by htpc-night, never by a switch.
      restartIfChanged = false;
      unitConfig.X-StopOnRemoval = false;
      environment = {
        HA_URL = cfg.haUrl;
        HA_NOTIFY_SERVICE = cfg.notifyService;
      };
      serviceConfig = {
        Type = "oneshot";
        # The token. `-` so a box without the file still runs the unit, which
        # then logs that it has no token.
        EnvironmentFile = "-${cfg.environmentFile}";
        ExecStart = lib.getExe htpc-update-alerts;
        # 3 s asking the cache, 10 s asking Home Assistant.
        TimeoutStartSec = "30s";
      };
    };
  };
}
