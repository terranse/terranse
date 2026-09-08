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
  # Guards two concurrent watchdog *runs* from both calling `nix-env
  # --rollback` -- e.g. an operator-triggered htpc-update-apply racing the
  # fifteen-minute timer, each detaching its own transient watchdog. See
  # the comment in htpc-update-watchdog below for exactly what this does
  # and does not protect against -- it is not what keeps the *declared*
  # htpc-update-watchdog.service from racing switch-to-configuration; that
  # is restartIfChanged on the service itself.
  watchdogLock = "${stateDir}/watchdog.lock";

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
      util-linux
    ];
    text = ''
      ${writeStateFn}

      # RemainAfterExit plus restartIfChanged=false on this unit (see
      # systemd.services.htpc-update-watchdog below -- stopIfChanged=false
      # sits alongside it as belt-and-braces, but restartIfChanged is what
      # actually does the work: it short-circuits switch-to-configuration
      # into skipping the unit before X-StopIfChanged is even read) mean
      # switch-to-configuration never starts, stops, or restarts this
      # *declared* unit at all, on any switch, once its boot-time run has
      # finished -- so the flock below is NOT what protects against that.
      # An earlier version of this comment claimed it did; it was wrong.
      # Tracing switch-to-configuration-ng's actual unit-diff logic showed
      # why that claim was wrong: a switch that changes this unit's own
      # definition puts the changed unit in *both* units_to_stop and
      # units_to_start (X-StopIfChanged defaults true) and BLOCKS on the
      # start job -- and htpc-update writes the marker, then calls
      # switch-to-configuration, then (only once that returns) detaches its
      # own transient watchdog. So the declared unit would start, and
      # acquire the lock, *before* the transient one exists at all -- it
      # would win the lock, not lose it, block the outer switch for
      # watchdogSeconds, and on an unhealthy result run a nested
      # switch-to-configuration from inside a unit the outer switch is
      # still blocking on, stopping that very unit mid-run and exiting 1 --
      # failing the outer switch, and therefore htpc-update.service, all
      # over again. The flock could not have closed that path; only keeping
      # switch-to-configuration from ever touching the declared unit does.
      #
      # What the lock actually guards: two *transient* watchdogs running
      # concurrently. htpc-update-apply.service (an operator accepting the
      # "update ready" popup) and the fifteen-minute htpc-update.timer can
      # both end up calling htpc-update around the same moment, and each
      # successful switch detaches its own htpc-update-watchdog-run-$$
      # transient unit. Without a lock, two such watchdogs polling the same
      # unhealthy backend would both decide to roll back and both call
      # `nix-env --rollback` -- the second `--rollback`, running after the
      # first has already succeeded, lands on whatever generation preceded
      # THIS one, silently rolling back two generations instead of one. The
      # lock makes the second of any two concurrent watchdog runs a no-op
      # instead.
      #
      # Losing this race is not an error -- the winner already has the work
      # in hand -- so it must exit 0, not whatever `flock` would otherwise
      # propagate. Do NOT "fix" this to exit 1: that reintroduces a failure
      # this guard exists to avoid.
      exec 200>${watchdogLock}
      if ! flock -n 200; then
        echo "htpc-update-watchdog: another instance already holds the lock; nothing to do" >&2
        exit 0
      fi

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

        # Load-bearing, not merely tidy: `nix store verify` (both the
        # pinned call below and the closure-wide one at the end) passes a
        # content-addressed path unconditionally, with zero signatures, by
        # design -- that is what makes fixed-output derivations able to
        # substitute at all. This CA ban on the *top level* is therefore
        # the entire defence against a `nix store add-path` payload; verify
        # itself provides none.
        ca=$(printf '%s' "$info" | jq -r --arg p "$path" '.[$p].ca')
        if [ "$ca" != "null" ]; then
          echo "htpc-stage: $path is content-addressed at the top level; refusing" >&2
          exit 1
        fi

        # This only proves *somebody* signed -- the Nix daemon lets any
        # unprivileged user attach an arbitrary signature with a key they
        # generated themselves (`nix key generate-secret` +
        # `nix store sign`). It is a cheap, early rejection of "not signed
        # at all"; it is not the trust check. The pinned verify below is.
        nsigs=$(printf '%s' "$info" | jq -r --arg p "$path" '.[$p].signatures | length')
        if [ "$nsigs" -eq 0 ]; then
          echo "htpc-stage: $path carries no signature at the top level; refusing" >&2
          exit 1
        fi

        # requireSignatures is on but no builder key has been configured
        # (roles.staged-updates.signingPublicKey is empty) -- refuse
        # outright rather than fall back to whatever this box already
        # trusts for substituting ordinary dependencies. cache.nixos.org-1
        # is in trusted-public-keys, and a signature from it proves
        # nothing about who assembled this closure; without a pinned key
        # of its own this box has no way to tell "CI built this" from
        # "any trusted third party signed something with -nixos-system-
        # in its name," which is root by a different door with no
        # forgery required. A plain shell variable, not a Nix-level
        # if/else baked into the generated text, so shellcheck does not
        # (correctly, in the empty-key case) see the verify call below as
        # unreachable dead code -- it is unreachable only for as long as
        # the key genuinely is not configured, which is the point.
        signing_public_key=${lib.escapeShellArg cfg.signingPublicKey}
        if [ -z "$signing_public_key" ]; then
          echo "htpc-stage: roles.staged-updates.signingPublicKey is not configured; refusing all updates until it is" >&2
          exit 1
        fi

        # The actual trust check, pinned to the builder's key material --
        # not its name. A signature's key *name* is attacker-chosen and
        # free to forge ("nix key generate-secret --key-name htpc-cache-1"
        # costs any unprivileged user nothing, and the daemon accepts the
        # resulting signature on a path it did not build); only the key
        # material itself cannot be. --option trusted-public-keys here
        # overrides the *client's* own list for this one invocation -- not
        # the daemon's, which an untrusted caller could not override anyway.
        # That is precisely why the pin binds: `nix store verify` checks
        # signatures client-side, against the list this invocation was
        # handed, so the narrowed list is authoritative here regardless of
        # whether the caller is a trusted user. A payload carrying a genuine
        # cache.nixos.org-1 signature (already in the daemon's list, for
        # substituting ordinary dependencies) *plus* a forged
        # "htpc-cache-1:..."-named signature is therefore refused: neither
        # the fake name nor the real third party is this box's actual
        # builder key.
        nix store verify --sigs-needed 1 \
          --option trusted-public-keys "$signing_public_key" \
          "$path"

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
        # top level). An additional check on the rest of the closure, using
        # the daemon's normal trusted-public-keys -- not a replacement for
        # the pinned top-level check above.
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

    signingPublicKey = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        The builder's actual public key -- the "name:base64" line
        `nix-store --generate-binary-cache-key` emits -- pinned
        cryptographically, not matched by name. A signature's key *name*
        is attacker-chosen and free to forge: any unprivileged user can
        `nix key generate-secret --key-name htpc-cache-1` and sign a path
        they did not build, and the daemon accepts it. Only the key
        material itself cannot be forged. A name-only check would also
        miss the case where a payload carries both a forged
        "htpc-cache-1:..." signature and a genuine signature from a key
        this box trusts for something else entirely (cache.nixos.org-1,
        for substituting ordinary dependencies) -- `nix store verify
        --sigs-needed 1` is satisfied by *any* trusted signature, so that
        combination clears a name check with no forgery of the trusted
        key required.

        Empty (the default) means the builder key has not been generated
        yet -- a human-gated step (Task 1). With requireSignatures on,
        htpc-stage then refuses every staged path outright, rather than
        falling back to whatever this box already trusts for unrelated
        purposes, so the update path is genuinely inert until this is
        set -- not merely claimed to be.
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

    # restartIfChanged = false is load-bearing here, not hygiene: this unit
    # runs switch-to-configuration inside its own ExecStart, so it must never
    # be a unit switch-to-configuration is willing to stop.
    # switch-to-configuration-ng puts a unit into its changed-unit diff when
    # that unit's state is `active` OR `activating` (main.rs:1238) -- and a
    # Type=oneshot service is `activating` for the whole of its ExecStart, so
    # htpc-update.service is in scope for the very switch its own ExecStart is
    # running. With X-RestartIfChanged and X-StopIfChanged unset (the
    # defaults) a changed .service lands in units_to_stop AND units_to_start
    # (main.rs:738-746), and switch-to-configuration issues
    # stop_unit(unit, "replace") and BLOCKS on it (main.rs:2202) before it ever
    # runs the activate script (main.rs:2231). An ordinary update would
    # therefore install the bootloader and then SIGTERM the cgroup running
    # switch-to-configuration itself: bootloader and
    # /nix/var/nix/profiles/system pointing at the new generation while
    # /run/current-system, /etc and every running service are still the old
    # one, the verify marker set, the unit `failed`, and no watchdog detached.
    # Every piece of recorded state would lie about what happened, and nothing
    # would converge until a reboot a suspended television may not take for
    # weeks.
    #
    # This is the common case, not a corner: htpc-update is a
    # writeShellApplication over coreutils/curl/gnugrep/jq/nix/systemd, so its
    # store path -- and therefore this ExecStart= -- changes on essentially
    # every nixpkgs bump. NixOS's own nixos-upgrade.service sets exactly these
    # two options for exactly this reason
    # (nixos/modules/tasks/auto-upgrade.nix).
    #
    # The reboot_required path was always safe: switch-to-configuration boot
    # returns right after installing the bootloader, before stopping anything.
    # It is the plain `switch` path -- the ordinary one -- that this closes.
    #
    # htpc-update-watchdog.service below also carries restartIfChanged = false,
    # for a related but different reason (it must not be *started* by a switch
    # at all, so the declared instance cannot race the transient one). Do not
    # collapse the two, and do not remove either.
    systemd.services.htpc-update = {
      description = "Activate a staged system generation when the TV is idle";
      restartIfChanged = false;
      unitConfig.X-StopOnRemoval = false;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe htpc-update;
        # systemd.service(5): the start timeout is DISABLED by default for
        # Type=oneshot. Nothing inside htpc-update bounds itself either --
        # switch-to-configuration blocks for as long as systemd takes, and the
        # only bounded call in the script is the --max-time 5 curl to
        # /system/activity. Without this, a wedged nix daemon or a hung switch
        # leaves the unit `activating` forever: no timeout, no failure, no
        # journal line, and a box that has silently stopped updating.
        #
        # 30min is a deliberate ceiling rather than a measurement. The slowest
        # legitimate switch observed anywhere in this work is ~90s (this
        # role's own VM test, under nested virtualisation on one vCPU), so
        # 30min cannot cut short real work; a run that reaches it is stuck,
        # and a failed unit is a far better outcome than an invisible one.
        # The same value is used on all four units of this role for the same
        # reason.
        TimeoutStartSec = "30min";
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

    # Same unit, same ExecStart, same switch-to-configuration -- only the
    # trigger differs (the viewer's popup rather than the timer), so it needs
    # the identical protection. See the long comment on
    # systemd.services.htpc-update above for the mechanism: `activating`
    # oneshots enter switch-to-configuration's changed-unit diff, and a changed
    # unit is stopped before the activate script runs.
    systemd.services.htpc-update-apply = {
      description = "Apply the staged generation now (the viewer accepted the popup)";
      restartIfChanged = false;
      unitConfig.X-StopOnRemoval = false;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe htpc-update} --force-idle";
        # See htpc-update above: Type=oneshot has no start timeout by default.
        TimeoutStartSec = "30min";
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
      # Without restartIfChanged = false, a switch that changes THIS unit's
      # own definition (an update to this role) puts it in
      # switch-to-configuration's units_to_stop AND units_to_start, and
      # switch-to-configuration BLOCKS on the resulting start job -- so the
      # declared unit runs, and acquires the flock in
      # htpc-update-watchdog's own script, before htpc-update has had any
      # chance to detach its own transient watchdog. That blocks the outer
      # switch for up to watchdogSeconds, and on an unhealthy result the
      # declared instance runs a nested switch-to-configuration from inside
      # a unit the outer switch is still blocking on -- stopping that very
      # unit mid-run and exiting 1, which fails the outer switch and
      # therefore htpc-update.service. restartIfChanged = false is what
      # stops switch-to-configuration from ever touching this unit on a
      # definition change at all (it short-circuits into its
      # units_to_skip list before X-StopIfChanged is even read, so
      # stopIfChanged below is belt-and-braces, not load-bearing, here --
      # kept in case that short-circuit is ever narrowed upstream, not
      # because removing it changes today's behaviour). Combined with
      # RemainAfterExit below, this unit is then started exactly once, by
      # its boot-time multi-user.target want, and never again by any
      # switch, changed-definition or not. The boot-time run itself is
      # unaffected -- it still runs, and still blocks
      # htpc-update-fetch.service (After = htpc-update-watchdog.service,
      # below), which is the whole reason a boot that exists to verify a
      # kernel update is not immediately handed a newer closure to stage
      # instead. Do not remove restartIfChanged as "redundant" with
      # RemainAfterExit -- RemainAfterExit alone still leaves the
      # definition-changed path wide open; see the long comment in
      # htpc-update-watchdog's own script.
      restartIfChanged = false;
      stopIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        # Keeps this unit "active (exited)" after its boot-time run, so an
        # unrelated switch (one that does NOT change this unit's own
        # definition) does not restart it either -- switch-to-configuration
        # otherwise restarts anything wanted-but-not-active, on every
        # switch. restartIfChanged above closes the remaining, more
        # dangerous case, where the definition DID change.
        RemainAfterExit = true;
        ExecStart = lib.getExe htpc-update-watchdog;
        # See htpc-update above: Type=oneshot has no start timeout by default.
        # This unit's legitimate worst case is the widest of the four -- a
        # full watchdogSeconds health poll (120s by default) followed by
        # `nix-env --rollback` and a complete switch-to-configuration -- and
        # 30min still clears that by more than an order of magnitude.
        TimeoutStartSec = "30min";
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
      # Same reasoning as htpc-update above -- this script also ends by
      # running htpc-update, which runs switch-to-configuration, so the unit
      # is `activating` while a switch that changes its own ExecStart= is in
      # progress. Its ExecStart embeds htpc-stage's and htpc-update's store
      # paths, so it changes whenever they do.
      restartIfChanged = false;
      unitConfig.X-StopOnRemoval = false;
      serviceConfig = {
        Type = "oneshot";
        # See htpc-update above: Type=oneshot has no start timeout by default,
        # and this unit has the least bounded body of the four. `curl` above
        # carries --max-time 20, but `nix copy --from` has no timeout of its
        # own at all, and neither do htpc-stage's `nix path-info` and `nix
        # store verify`. A stalled cache or a wedged nix daemon otherwise
        # parks this unit in `activating` with no failure and no further
        # journal line after "fetching". 30min is chosen to sit far above a
        # legitimate multi-GB closure pull over the LAN, which is what makes
        # it safe to fail on.
        TimeoutStartSec = "30min";
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

          # $pointer is an unauthenticated remote string -- whatever bytes
          # answer at that URL -- and it reaches `nix copy` BELOW, before
          # htpc-stage's own guard ever sees it. `nix copy --from <uri>
          # <installable>` takes an *installable*, not a path: it evaluates
          # (confirmed against nix 2.34.8). So without this guard, anyone able
          # to control those bytes -- write access to the cache dataset, the
          # nginx container serving it, LAN DNS or TLS interception -- serves
          # `git+https://evil.example/x#p` and root's Nix evaluates and builds
          # it on the next boot, bypassing every signature check because none
          # is reached. This is the same defect class already closed inside
          # htpc-stage, and deliberately the identical guard: see the long
          # comment there for why it is a bash pattern match against the whole
          # variable rather than a line-oriented grep.
          if [[ ! $pointer =~ ^/nix/store/[0-9a-z]{32}-[^/[:space:]]+$ ]]; then
            echo "htpc-update-fetch: $pointer is not a single literal store path; refusing" >&2
            exit 1
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
