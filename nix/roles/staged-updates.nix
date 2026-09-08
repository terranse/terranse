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
      # A staged-at file that is missing, empty (an interrupted write), or
      # otherwise not a plain integer must not reach the arithmetic below --
      # a non-numeric string is a bash syntax error under `$(( ))` that would
      # kill write_state under set -e, and "0" already means "nothing
      # staged", which age_seconds should say plainly rather than reporting
      # the distance from the Unix epoch.
      [[ $staged =~ ^[0-9]+$ ]] || staged=0
      if [ "$staged" -eq 0 ]; then
        age=0
      else
        age=$(( $(date -u +%s) - staged ))
      fi
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

      ${
        if !cfg.requireHealthy then
          ''
            # No health endpoint exists to ask yet -- home-player (Task 7) is
            # not deployed on this machine. Treating a fresh activation as
            # "nothing to verify" -- neither healthy nor unhealthy -- is
            # deliberate: rolling back on an absent backend would revert
            # every good update and then permanently brick the update path,
            # since htpc-stage refuses a bad-revisions entry forever. Flip
            # roles.staged-updates.requireHealthy back to true in
            # nix/machines.nix the moment home-player lands.
            rm -f ${verifyMarker}
            echo "htpc-update-watchdog: requireHealthy is off; leaving $pending as-is"
            write_state none "$pending" 0
            exit 0
          ''
        else
          ''
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

            if ! nix-env -p ${systemProfile} --rollback; then
              # No earlier generation exists (e.g. this is the first
              # generation this role ever staged). $pending is already on
              # the bad-revisions list above, so it will not be re-offered;
              # the box just stays on it until a human intervenes, which
              # state.json now says outright rather than claiming a
              # rollback happened when it did not.
              #
              # "rollback-failed" is a deliberate extension beyond the
              # contract's documented reason enum (none|busy|bad|
              # rebooting|rolled-back). A rollback that failed is a
              # genuinely distinct state from "rolled-back" -- reporting
              # rolled-back here would tell home-player's popup the box is
              # on a good generation when it is still on the bad one. Do
              # not "fix" this back to an existing value.
              echo "htpc-update-watchdog: no earlier generation to roll back to" >&2
              write_state rollback-failed "$pending" 0
              exit 1
            fi

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
          ''
      }
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

      # An `if`, not `[ ... ] && force_idle=1`: writeShellApplication sets
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

      # Not `exec`: switch-to-configuration can restart htpc-update.service
      # itself, when the update touches this very role -- exactly the class
      # of update most in need of a watchdog. `exec` would then either die
      # along with the unit's own restart or run the watchdog from inside
      # the unit racing its own restart. A transient unit, detached from
      # htpc-update.service's lifecycle, avoids both -- but only if this
      # line is actually reached: if switch-to-configuration kills this
      # process first, no watchdog is spawned at all here, and the marker
      # sits unverified until htpc-update-watchdog.service's own
      # multi-user.target start finds it on the *next* boot, whenever that
      # is. The unit name includes $$ so two overlapping watchdogs -- the
      # 15-minute timer racing an operator-triggered htpc-update-apply --
      # get distinct names instead of one systemd-run failing under set -e
      # because --collect only reaps a unit that has already finished.
      systemd-run --collect --unit="htpc-update-watchdog-run-$$" \
        ${lib.getExe htpc-update-watchdog}
    '';
  };

  htpc-stage = pkgs.writeShellApplication {
    name = "htpc-stage";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      jq
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

      # $path must name exactly one store object -- a literal path, not a
      # Nix installable (a flake reference, ".", a subpath into an output,
      # ...). Without this, the commands below evaluate whatever $path
      # names instead of inspecting a store object, and `sudo htpc-stage .`
      # run from a directory deploy controls evaluates and builds arbitrary
      # Nix under root's trusted-user daemon.
      case "$path" in
        /nix/store/*) ;;
        *)
          echo "htpc-stage: $path must be a literal /nix/store path" >&2
          exit 1
          ;;
      esac
      # A bash pattern match against the whole variable, not a
      # line-oriented `grep`: piping $path through `grep -qE '^...$'`
      # anchors ^ and $ to each *line* grep reads, so a two-line string
      # such as "/nix/store/junk\n/nix/store/<real-hash>-name" would match
      # on its second line even though $path as a whole is not one store
      # path. `[^/[:space:]]+` (not `[^/]+`) also keeps a newline hidden
      # inside the name segment from being swallowed by the character
      # class itself.
      if [[ ! $path =~ ^/nix/store/[0-9a-z]{32}-[^/[:space:]]+$ ]]; then
        echo "htpc-stage: $path must name exactly one store object" >&2
        exit 1
      fi

      if [ ! -e "$path" ]; then
        echo "htpc-stage: $path is not in the store" >&2
        exit 1
      fi

      ${lib.optionalString cfg.requireSignatures ''
        # Everything above this line only checks shape and the local
        # bad-revisions list; nothing has proven $path is trustworthy yet.
        # Nix treats a content-addressed path as self-certifying -- `nix
        # store verify` accepts it with zero real signatures -- and any
        # unprivileged user can create one via `nix store add-path`. That is
        # fine deep inside a closure (every fetched source tarball is a
        # legitimate fixed-output/CA derivation) but must never be true of
        # the top level about to be handed to switch-to-configuration, so
        # the top level is checked on its own terms before the closure-wide
        # check below runs.
        #
        # `nix path-info --json` reports an object keyed by store path (not
        # an array), so the query has to select by $path rather than by
        # position.
        info=$(nix path-info --json --json-format 1 "$path")

        # A guard whose own machinery breaking must fail closed, not pass.
        # If path-info's output shape ever changes underneath this script --
        # a renamed field, a different top-level structure -- `.ca` and
        # `.signatures` below would read as missing, which jq's `-r`
        # renders as the string "null" and the empty count 0 respectively:
        # exactly what "not content-addressed" and "no signature" already
        # look like. A check that silently degrades into always passing on
        # its own breakage is not a check. Assert the shape is what is
        # expected before reading either value out of it.
        if ! printf '%s' "$info" | jq -e --arg p "$path" \
             'has($p) and (.[$p] | has("ca")) and (.[$p] | has("signatures"))' \
             >/dev/null; then
          echo "htpc-stage: unexpected nix path-info output for $path; refusing" >&2
          exit 1
        fi

        ca=$(printf '%s' "$info" | jq -r --arg p "$path" '.[$p].ca')
        if [ "$ca" != "null" ]; then
          echo "htpc-stage: $path is content-addressed at the top level; refusing" >&2
          exit 1
        fi

        # This only proves *somebody* signed -- the Nix daemon lets any
        # unprivileged user attach an arbitrary signature with a key they
        # generated themselves (`nix key generate-secret` +
        # `nix store sign`). It is a cheap, early rejection of "not signed
        # at all"; it is not the trust check. signingKeyName below is.
        nsigs=$(printf '%s' "$info" | jq -r --arg p "$path" '.[$p].signatures | length')
        if [ "$nsigs" -eq 0 ]; then
          echo "htpc-stage: $path carries no signature at the top level; refusing" >&2
          exit 1
        fi

        # The actual trust check. cache.nixos.org-1 is in
        # trusted-public-keys so ordinary dependencies can be substituted,
        # but a signature from it says nothing about who assembled *this*
        # closure -- without this, any cache.nixos.org-signed, non-CA path
        # whose basename contains "-nixos-system-" (a Hydra-built installer
        # closure, say) would clear every check above and below. That is
        # root by a different door: deploy stages a foreign, legitimately
        # signed NixOS system with, for instance, root autologin and no
        # firewall. Require a signature specifically from this box's own
        # builder key, not merely from something trusted in general.
        if ! printf '%s' "$info" | jq -e --arg p "$path" --arg key "${cfg.signingKeyName}:" \
             '.[$p].signatures | any(startswith($key))' >/dev/null; then
          echo "htpc-stage: $path is not signed by ${cfg.signingKeyName}; refusing" >&2
          exit 1
        fi

        # Cheap defence in depth: the only thing this ever legitimately
        # stages is a system closure's toplevel, never a bare derivation
        # output.
        case "$(basename "$path")" in
          *-nixos-system-*) ;;
          *)
            echo "htpc-stage: $path does not look like a nixos-system toplevel" >&2
            exit 1
            ;;
        esac

        # The closure-wide check: everything $path transitively depends on
        # must verify against a trusted key (or be legitimately
        # content-addressed -- see above for why that allowance stops at the
        # top level). An additional, narrower assertion on top of this, not
        # a replacement for it.
        nix store verify --recursive --sigs-needed 1 "$path"
      ''}

      install -d -m 0755 ${stateDir}
      touch ${badRevisions}
      if grep -qxF "$path" ${badRevisions}; then
        echo "htpc-stage: $path is on the bad-revisions list; refusing" >&2
        exit 1
      fi

      # A GC root, so nix.gc cannot eat the closure between staging and
      # activation. $path is the same string validated above -- not a
      # symlink target, not a re-resolved path -- so the root can only ever
      # point at the one store object that was actually checked.
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

    signingKeyName = lib.mkOption {
      type = lib.types.str;
      default = "htpc-cache-1";
      description = ''
        Name of the signing key the staged toplevel must itself carry a
        signature from -- not merely any key this box trusts.
        cache.nixos.org-1 is trusted too (for substituting ordinary
        dependencies), but a signature from it proves nothing about who
        assembled a given closure; without this check, any
        cache.nixos.org-signed, non-CA nixos-system-* path -- a foreign,
        Hydra-built installer closure, say -- would clear every other
        check here. "htpc-cache-1" is the name Task 1's
        `nix-store --generate-binary-cache-key htpc-cache-1 ...` step
        generates. Until that key exists both in this box's
        trusted-public-keys and in ship.sh's SIGNING_KEY_FILE, nothing can
        ever satisfy this check and the update path is inert by design --
        that is a human-gated prerequisite, not a regression.
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

    requireHealthy = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Roll back a freshly activated generation that never reports
        healthy. Off means "nothing to verify", not "healthy" -- the
        watchdog clears its marker and leaves the generation in place
        without adding it to bad-revisions. Needed until the home-player
        role (Task 7) actually serves ${cfg.healthUrl}/health: otherwise
        every update times out waiting on a backend that does not exist,
        gets rolled back, and is then refused forever by htpc-stage's
        bad-revisions check.
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
    #
    # Do NOT add `cfg.deployUser` to `wheel` when that account is declared.
    # base.nix already grants wheel `NOPASSWD:SETENV: ALL` -- putting deploy
    # there, the reflex for "it's just an SSH account", makes this
    # one-command rule irrelevant and hands CI passwordless root.
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

          # This still goes through the ordinary idle check in htpc-update --
          # someone may have just pressed the power button. A failed
          # /system/activity request already reads as idle (home-player is
          # not deployed yet), so this behaves the same as before; once that
          # endpoint is real, this is what stops a kernel-update reboot from
          # landing in a viewer's face on the very boot that woke the box up.
          ${lib.getExe htpc-stage} --no-activate "$pointer"
          ${lib.getExe htpc-update}
        '';
      };
    };
  };
}
