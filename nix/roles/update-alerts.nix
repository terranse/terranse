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
      # When the cache last gave a build time that was a number. Without it a
      # cache that cannot be reached looks the same as a fresh one, and the most
      # likely way for updates to stop is the least noisy.
      build_seen=${stateDir}/alerts-build-seen

      put() {
        printf '%s\n' "$2" > "$1.new" && mv "$1.new" "$1"
      }

      check() {
        touch "$sent"
        local now
        now=$(date -u +%s)

        # state.json is only read here. The updater and its watchdog write it,
        # and a second writer would lose theirs; the ages are worked out below.
        # A file that is missing or unreadable costs the checks that need it,
        # and no more.
        local state_ok=0 reason="" pending="" rolled="" staged=0
        if jq -e 'type == "object"' "$state" >/dev/null 2>&1; then
          state_ok=1
          reason=$(jq -r '.reason // ""' "$state")
          pending=$(jq -r '.pending // ""' "$state")
          rolled=$(jq -r '.rolled_back_at // ""' "$state")
          staged=$(jq -r '.staged_at // 0' "$state")
        fi
        [[ $staged =~ ^[0-9]+$ ]] || staged=0
        local age=0
        if [ "$staged" -ne 0 ]; then age=$(( now - staged )); fi

        # Asked again rather than read from state.json: on a night with nothing
        # to fetch, nothing else has looked at the cache since the last run.
        local build_age seen_at
        build_age=$(/run/current-system/sw/bin/htpc-build-age) || build_age=null
        [[ $build_age =~ ^[0-9]+$ ]] || build_age=null
        seen_at=$(cat "$build_seen" 2>/dev/null) || seen_at=""
        if [ "$build_age" != null ] || [[ ! $seen_at =~ ^[0-9]+$ ]]; then
          # A box that has never heard from the cache starts counting now, so it
          # says something three nights after it first ran, not never.
          put "$build_seen" "$now"
          seen_at=$now
        fi
        local unheard=$(( now - seen_at ))
        if [ "$unheard" -lt 0 ]; then unheard=0; fi

        local keys=() lines=() flags=()
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

        # Once per period of each kind. A period ends only when that kind is
        # known to be over: a night the cache cannot be reached proves nothing
        # either way, so it neither starts nor ends one.
        stale() {
          local flag="${stateDir}/alerts-stale-$1"
          case "$2" in
            stale)
              if [ ! -e "$flag" ]; then flags+=("$flag"); lines+=("$3"); fi
              ;;
            fresh) rm -f "$flag" ;;
          esac
        }
        local verdict
        verdict=unknown
        if [ "$state_ok" -eq 1 ]; then
          if [ "$age" -ge ${toString staleSeconds} ]; then verdict=stale; else verdict=fresh; fi
        fi
        stale waiting "$verdict" "An update has been waiting for 3 nights without being taken."
        verdict=unknown
        if [ "$build_age" != null ]; then
          if [ "$build_age" -ge ${toString staleSeconds} ]; then verdict=stale; else verdict=fresh; fi
        fi
        stale build "$verdict" "No update has been built for 3 nights."
        verdict=fresh
        if [ "$build_age" = null ]; then
          verdict=unknown
          if [ "$unheard" -ge ${toString staleSeconds} ]; then verdict=stale; fi
        fi
        stale cache "$verdict" "Cannot reach the update cache for 3 nights."

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
        local item
        for item in "''${keys[@]}"; do printf '%s\n' "$item" >> "$sent"; done
        for item in "''${flags[@]}"; do touch "$item"; done
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
