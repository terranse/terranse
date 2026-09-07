# The receiver and the activation policy.
#
# The box does not accept "an update". It accepts one specific store path,
# signed by a key it already trusts, recorded as a generation it can roll back
# from, and activated by its own root-owned policy at a moment it chose. CI
# ships bytes and writes a pointer; trust is enforced here, by the box.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.roles.staged-updates;

  stateDir = "/var/lib/htpc-update";
  pendingRoot = "/nix/var/nix/gcroots/htpc-pending";
  badRevisions = "${stateDir}/bad-revisions";
  stagedAt = "${stateDir}/staged-at";
  # Written just before an activation, cleared once the result is proved
  # healthy. Its presence on a fresh boot is how a kernel update gets
  # watchdogged at all -- nothing can poll across a reboot.
  verifyMarker = "${stateDir}/verify-after-reboot";

  systemProfile = "/nix/var/nix/profiles/system";

  # Shared between the policy engine and the watchdog, so state.json has
  # exactly one writer shape.
  writeStateFn = ''
    write_state() {
      local reason="$1" pending="$2" reboot="$3"
      local staged age
      staged=$(cat ${stagedAt} 2>/dev/null || echo 0)
      age=$(( $(date -u +%s) - staged ))
      jq -n \
        --arg reason "$reason" \
        --arg pending "$pending" \
        --arg current "$(readlink -f /run/current-system)" \
        --argjson reboot_required "$reboot" \
        --argjson staged_at "$staged" \
        --argjson age_seconds "$age" \
        '{ reason: $reason, pending: $pending, current: $current,
           reboot_required: ($reboot_required == 1),
           staged_at: $staged_at, age_seconds: $age_seconds }' \
        > ${stateDir}/state.json.new
      mv ${stateDir}/state.json.new ${stateDir}/state.json
    }
  '';

  htpc-update-watchdog = pkgs.writeShellApplication {
    name = "htpc-update-watchdog";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      gnugrep
      jq
      nix
      systemd
    ];
    text = ''
      ${writeStateFn}

      [ -f ${verifyMarker} ] || exit 0
      pending=$(cat ${verifyMarker})

      healthy=0
      deadline=$(( $(date +%s) + ${toString cfg.watchdogSeconds} ))
      while [ "$(date +%s)" -lt "$deadline" ]; do
        if curl -fsS --max-time 5 ${cfg.healthUrl}/health >/dev/null 2>&1; then
          ${lib.optionalString cfg.requireKioskUnit ''
            # A backend answering /health while the screen renders nothing is
            # the failure this narrows. It does not close it.
            if ! systemctl --user --machine=${cfg.kioskUser}@.host \
                 is-active --quiet home-player-shell.service; then
              sleep 5
              continue
            fi
          ''}
          healthy=1
          break
        fi
        sleep 5
      done

      if [ "$healthy" -eq 1 ]; then
        rm -f ${verifyMarker}
        echo "htpc-update-watchdog: $pending is healthy"
        write_state none "$pending" 0
        exit 0
      fi

      echo "htpc-update-watchdog: $pending never became healthy; rolling back" >&2

      # Barred by exact path, and only this path. A later, different revision
      # is unaffected -- otherwise the 15-minute timer would rollback-loop on
      # the same closure forever.
      printf '%s\n' "$pending" >> ${badRevisions}
      rm -f ${pendingRoot} ${verifyMarker}

      nix-env -p ${systemProfile} --rollback
      restored=$(readlink -f ${systemProfile})
      booted=$(readlink -f /run/booted-system)
      write_state rolled-back "$pending" 0

      if [ "$(readlink -f "$restored/kernel")" != "$(readlink -f "$booted/kernel")" ]; then
        "$restored/bin/switch-to-configuration" boot
        systemctl reboot
      else
        "$restored/bin/switch-to-configuration" switch
      fi
      exit 1
    '';
  };

  htpc-update = pkgs.writeShellApplication {
    name = "htpc-update";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      gnugrep
      jq
      nix
      systemd
    ];
    text = ''
      ${writeStateFn}

      # An `if`, not `[ … ] && force_idle=1`: writeShellApplication sets
      # `set -e`, under which a bare test-and-assign line exits the script the
      # moment the test is false.
      force_idle=0
      if [ "''${1:-}" = "--force-idle" ]; then
        force_idle=1
      fi

      install -d -m 0755 ${stateDir}
      touch ${badRevisions}

      if [ ! -L ${pendingRoot} ]; then
        write_state none "" 0
        exit 0
      fi
      pending=$(readlink -f ${pendingRoot})
      current=$(readlink -f /run/current-system)

      if [ "$pending" = "$current" ]; then
        write_state none "$pending" 0
        exit 0
      fi

      if grep -qxF "$pending" ${badRevisions}; then
        echo "htpc-update: $pending is a known-bad revision; not activating" >&2
        write_state bad "$pending" 0
        exit 0
      fi

      # A changed kernel or initrd cannot be switched into a running system;
      # it has to be written to the boot loader and rebooted into.
      reboot_required=0
      if [ "$(readlink -f "$pending/kernel")" != "$(readlink -f /run/booted-system/kernel)" ] ||
         [ "$(readlink -f "$pending/initrd")" != "$(readlink -f /run/booted-system/initrd)" ]; then
        reboot_required=1
      fi

      busy=false
      if [ "$force_idle" -eq 0 ]; then
        # /system/activity is home-player's side of the contract and may not
        # exist yet. A failed request reads as idle, so the loop works before
        # the popup lands.
        busy=$(curl -fsS --max-time 5 ${cfg.healthUrl}/system/activity 2>/dev/null \
               | jq -r '.busy' 2>/dev/null || echo false)
      fi

      if [ "$busy" = "true" ]; then
        # Change nothing. The timer re-checks, so the update also lands on its
        # own the moment playback ends, whether or not the popup is ever shown
        # or accepted.
        echo "htpc-update: busy; leaving $pending staged"
        write_state busy "$pending" "$reboot_required"
        exit 0
      fi

      echo "htpc-update: activating $pending (reboot_required=$reboot_required)"

      # --set is what creates the generation, and therefore the rollback.
      nix-env -p ${systemProfile} --set "$pending"
      printf '%s\n' "$pending" > ${verifyMarker}

      if [ "$reboot_required" -eq 1 ]; then
        "$pending/bin/switch-to-configuration" boot
        write_state rebooting "$pending" 1
        # The watchdog cannot poll across a reboot, so it runs on the way back
        # and finds the marker written above.
        systemctl reboot
        exit 0
      fi

      "$pending/bin/switch-to-configuration" switch
      exec ${lib.getExe htpc-update-watchdog}
    '';
  };

  htpc-stage = pkgs.writeShellApplication {
    name = "htpc-stage";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      nix
      systemd
    ];
    text = ''
      activate=1
      if [ "''${1:-}" = "--no-activate" ]; then
        activate=0
        shift
      fi
      path="''${1:?usage: htpc-stage [--no-activate] <store-path>}"

      if [ ! -e "$path" ]; then
        echo "htpc-stage: $path is not in the store" >&2
        exit 1
      fi

      ${lib.optionalString cfg.requireSignatures ''
        # The first thing this does, before the path becomes reachable from a
        # GC root. A stolen deploy key can upload bytes; it cannot make the
        # box run them.
        nix store verify --recursive --sigs-needed 1 "$path"
      ''}

      install -d -m 0755 ${stateDir}
      touch ${badRevisions}
      if grep -qxF "$path" ${badRevisions}; then
        echo "htpc-stage: $path is on the bad-revisions list; refusing" >&2
        exit 1
      fi

      # A GC root, so nix.gc cannot eat the closure between staging and
      # activation.
      ln -sfn "$path" ${pendingRoot}
      date -u +%s > ${stagedAt}
      echo "htpc-stage: staged $path"

      if [ "$activate" -eq 1 ]; then
        systemctl start --no-block htpc-update.service
      fi
    '';
  };
in
{
  options.roles.staged-updates = {
    enable = lib.mkEnableOption "receiving and activating staged system generations";

    cacheUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://nix-cache.edholm.cc";
      description = "Binary cache to pull from when a push did not land.";
    };

    deployUser = lib.mkOption {
      type = lib.types.str;
      default = "deploy";
      description = "Account CI pushes closures to. Gets exactly one sudo entry.";
    };

    kioskUser = lib.mkOption {
      type = lib.types.str;
      default = "tv";
      description = "Account whose home-player-shell user unit the watchdog checks.";
    };

    backendUser = lib.mkOption {
      type = lib.types.str;
      default = "home-player";
      description = "Account allowed, by polkit, to start htpc-update-apply.service.";
    };

    healthUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:9600";
      description = "Backend base URL for /health and /system/activity.";
    };

    watchdogSeconds = lib.mkOption {
      type = lib.types.int;
      default = 120;
      description = "How long a freshly activated generation has to look healthy.";
    };

    requireSignatures = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Verify staged closures against the trusted keys. Only the nixosTest
        turns this off -- a test VM has no builder key, and the thing under
        test is the policy, not the cryptography.
      '';
    };

    requireKioskUnit = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Require the kiosk shell's user unit to be active before calling a
        generation healthy. Off in the nixosTest, which runs no kiosk.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      htpc-stage
      htpc-update
      htpc-update-watchdog
    ];

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0755 root root -"
      "f ${badRevisions} 0644 root root -"
    ];

    # Exactly one command, and its first action is to verify signatures. This
    # is the whole privilege CI has on the box.
    security.sudo.extraRules = [
      {
        users = [ cfg.deployUser ];
        commands = [
          {
            command = "/run/current-system/sw/bin/htpc-stage";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];

    # The backend gets no sudo and no shell; it can request exactly one
    # pre-declared action, which is how "Update ready -- apply now?" works
    # without handing the UI any privilege.
    security.polkit.enable = true;
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            action.lookup("unit") == "htpc-update-apply.service" &&
            action.lookup("verb") == "start" &&
            subject.user == "${cfg.backendUser}") {
          return polkit.Result.YES;
        }
      });
    '';

    systemd.services.htpc-update = {
      description = "Activate a staged system generation when the TV is idle";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe htpc-update;
      };
    };

    systemd.timers.htpc-update = {
      description = "Re-check the staged generation";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10min";
        OnUnitActiveSec = "15min";
        Persistent = true;
      };
    };

    systemd.services.htpc-update-apply = {
      description = "Apply the staged generation now (the viewer accepted the popup)";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe htpc-update} --force-idle";
      };
    };

    systemd.services.htpc-update-watchdog = {
      description = "Verify a freshly activated generation and roll back if it is unhealthy";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "home-player-backend.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe htpc-update-watchdog;
      };
    };

    systemd.services.htpc-update-fetch = {
      description = "Fetch the published system closure from the binary cache";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      # After the watchdog, so a boot that exists to verify a kernel update is
      # not immediately handed a newer closure to stage instead.
      after = [
        "network-online.target"
        "htpc-update-watchdog.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "htpc-update-fetch" ''
          set -euo pipefail
          export PATH=${
            lib.makeBinPath (with pkgs; [
              coreutils
              curl
              nix
            ])
          }:$PATH

          pointer=$(curl -fsS --max-time 20 \
            "${cfg.cacheUrl}/pointers/${config.networking.hostName}" || true)
          if [ -z "$pointer" ]; then
            echo "htpc-update-fetch: no pointer at ${cfg.cacheUrl}"
            exit 0
          fi

          current=$(readlink -f /run/current-system)
          [ "$pointer" != "$current" ] || exit 0
          if [ -L ${pendingRoot} ] && [ "$(readlink -f ${pendingRoot})" = "$pointer" ]; then
            exit 0
          fi

          echo "htpc-update-fetch: fetching $pointer"
          nix copy --from "${cfg.cacheUrl}" "$pointer"

          # Nobody is watching at boot, so this path activates immediately.
          # It is what catches every push where wake-on-LAN did not land.
          ${lib.getExe htpc-stage} --no-activate "$pointer"
          ${lib.getExe htpc-update} --force-idle
        '';
      };
    };
  };
}
