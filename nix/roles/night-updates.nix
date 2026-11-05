# The box sleeps with real S3, wakes itself at night, updates, and goes back to
# sleep with the TV off.
#
# Home Player's Sleep button owns suspend. This role adds the timer that wakes
# the box, a job that runs the ordinary update path from staged-updates.nix and
# then decides what the box should do next, and what the shell needs in order
# not to light the TV for that wake.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.roles.night-updates;
  staged = config.roles.staged-updates;

  # Read by Home Player's shell (shell/src-tauri/src/resume.rs) as one plain
  # integer, by an account that is not root. Anything else there lights the TV
  # at night.
  runDir = "/run/htpc-night";
  scheduledWake = "${runDir}/scheduled-wake";
  resumedAt = "${runDir}/resumed-at";
  inputSeen = "${runDir}/input-seen";

  # staged-updates.nix's own paths.
  stateDir = "/var/lib/htpc-update";
  pendingRoot = "/nix/var/nix/gcroots/htpc-pending";

  # "This boot's job is to go back to sleep." On disk, because the reboot an
  # update asks for happens from inside htpc-update, so it has to be in place
  # before the fetch. Holds the boot ID and the time of the run that wrote it.
  resuspendMarker = "${stateDir}/resuspend-after-boot";
  # A run is bounded by its 30 minutes, so an older marker is a run that died
  # and a boot with nothing to do with it (a power cut, weeks later).
  markerMaxAgeSeconds = 3600;

  # How long after a resume the timer's job may start and still be that wake.
  # The same figure as the shell's SCHEDULED_WAKE_TOLERANCE_SECONDS.
  resumeWindowSeconds = 180;
  # The RTC counts whole seconds, so a timed wake can land just ahead of the
  # time it was set for. Any earlier than this and a person woke the box.
  earlyWakeSeconds = 10;

  htpc-night-decide = pkgs.writeShellApplication {
    name = "htpc-night-decide";
    text = ''
      # Pure: the facts arrive in the environment, the answer leaves on stdout.
      # A box that was already awake is nobody's business here. After that a
      # person outranks everything, including a pending reboot: keeping the
      # marker would put the box to sleep under them on the next boot.
      if [ "''${TIMED:-0}" != 1 ]; then
        echo stay-awake
      elif [ "''${INPUT_SEEN:-0}" = 1 ]; then
        echo tv-on
      elif [ "''${BUSY:-0}" = 1 ]; then
        echo stay-awake
      elif [ "''${REBOOT_PENDING:-0}" = 1 ]; then
        echo keep-marker
      else
        echo suspend
      fi
    '';
  };

  updateInFlightFn = ''
    # htpc-update-fetch runs its switch inside its own unit, so only the process
    # shows that one.
    update_in_flight() {
      local unit
      for unit in htpc-update.service htpc-update-apply.service; do
        if [ "$(systemctl show -P ActiveState "$unit")" = activating ]; then
          return 0
        fi
      done
      pgrep -f switch-to-configuration >/dev/null
    }
  '';

  # Asked for from outside the job, a moment after it ends, so the timer has its
  # next elapse by then: while the unit it triggers is active a timer has none,
  # and with none no alarm is armed for the next night.
  htpc-night-suspend = pkgs.writeShellApplication {
    name = "htpc-night-suspend";
    runtimeInputs = with pkgs; [
      coreutils
      procps
      systemd
    ];
    text = ''
      ${updateInFlightFn}

      # htpc-update's timer can fire between the job's last look and this. Usually
      # that is a moment's work, and giving up would leave the box awake until
      # someone puts it to sleep, because the next night's wake finds it awake.
      ask() {
        local waited=0
        while update_in_flight && [ "$waited" -lt 120 ]; do
          sleep 2
          waited=$(( waited + 2 ))
        done
        if update_in_flight; then
          echo "htpc-night: an update is still under way; not suspending" >&2
          exit 1
        fi
        ${cfg.suspendCommand}
      }

      if ! ask; then
        echo "htpc-night: suspend failed; trying once more" >&2
        sleep 5
        ask
      fi
    '';
  };

  sleepHook = pkgs.writeShellApplication {
    name = "htpc-night-sleep-hook";
    runtimeInputs = with pkgs; [
      coreutils
      systemd
    ];
    text = ''
      put() {
        printf '%s\n' "$2" > "$1.new"
        chmod 0644 "$1.new"
        mv "$1.new" "$1"
      }

      case "''${1:-}" in
        pre)
          # Someone pressed Sleep during a run. Stopped here, before the sleep,
          # so the timer gets its next elapse and arms the alarm for tomorrow, and
          # with no marker, because a person has now said what the box should do.
          # Not Conflicts=sleep.target: the timer's job starts while sleep.target
          # is still active on the way out of suspend, and would stop it.
          for unit in htpc-night.service htpc-night-after-boot.service; do
            if [ "$(systemctl show -P ActiveState "$unit")" = activating ]; then
              timeout 20 systemctl stop "$unit" || echo "htpc-night: could not stop $unit" >&2
              rm -f ${resuspendMarker}
            fi
          done

          # A pending suspend of the job's own would otherwise fire after the next
          # wake, on a clock that stood still, and put the box to sleep under
          # whoever woke it. When this sleep is that suspend, its request has
          # already been accepted, so stopping what is left of it changes nothing.
          timeout 20 systemctl stop htpc-night-suspend.timer htpc-night-suspend.service ||
            echo "htpc-night: could not cancel a pending suspend" >&2

          # Worked out rather than asked of the timer, which reports nothing while
          # the job is running. Only a timer that is really stopped has no schedule,
          # and then every wake is a person's, which is right for one that will not
          # fire.
          next=""
          if systemctl is-active --quiet htpc-night.timer; then
            now=$(date +%s)
            next=$(date -d "today ${cfg.wakeTime}" +%s) || next=""
            if [[ $next =~ ^[0-9]+$ ]] && [ "$next" -le "$now" ]; then
              next=$(date -d "tomorrow ${cfg.wakeTime}" +%s) || next=""
            fi
          fi
          if [[ $next =~ ^[0-9]+$ ]]; then
            put ${scheduledWake} "$next"
          else
            rm -f ${scheduledWake}
          fi
          ;;
        post)
          put ${resumedAt} "$(date +%s)"
          ;;
      esac
    '';
  };

  htpc-night = pkgs.writeShellApplication {
    name = "htpc-night";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      htpc-night-decide
      jq
      libinput
      procps
      systemd
    ];
    text = ''
      started=$(date +%s)
      # Inside the unit's own 30 minutes, so that a fetch which never ends
      # still reaches the decision instead of the unit being killed before it.
      budget=''${HTPC_NIGHT_BUDGET_SECONDS:-1620}
      deadline=$(( started + budget ))
      # Past the budget nothing new starts, but a switch already under way is
      # still given time to finish. Still inside the unit's 30 minutes.
      hard_deadline=$(( deadline + 120 ))
      boot_id=$(cat /proc/sys/kernel/random/boot_id)

      epoch_in() {
        local value
        value=$(cat "$1" 2>/dev/null) || value=""
        if [[ $value =~ ^[0-9]+$ ]]; then echo "$value"; else echo 0; fi
      }

      timed=0
      if [ "''${1:-}" = "--after-boot" ]; then
        [ -e ${resuspendMarker} ] || exit 0
        read -r marker_boot marker_at < ${resuspendMarker} || true
        # Still this boot: the run that wrote it is alive and in charge. This
        # unit starts on the first switch that introduces it, too.
        if [ "''${marker_boot:-}" = "$boot_id" ]; then
          exit 0
        fi
        if [[ ''${marker_at:-} =~ ^[0-9]+$ ]] && [ $(( started - marker_at )) -le ${toString markerMaxAgeSeconds} ]; then
          timed=1
        else
          echo "htpc-night: ignoring a marker from an old run"
          rm -f ${resuspendMarker}
          exit 0
        fi
      else
        # Asleep when the timer came due, and woken by it: the resume is recent
        # and not ahead of the schedule. A box somebody woke a minute early was
        # awake when the timer fired, and stays that way.
        resumed=$(epoch_in ${resumedAt})
        scheduled=$(epoch_in ${scheduledWake})
        since=$(( started - resumed ))
        if [ "$resumed" -gt 0 ] && [ "$scheduled" -gt 0 ] &&
           [ "$since" -ge 0 ] && [ "$since" -le ${toString resumeWindowSeconds} ] &&
           [ "$resumed" -ge $(( scheduled - ${toString earlyWakeSeconds} )) ]; then
          timed=1
        fi
      fi
      echo "htpc-night: timed=$timed"

      tv_on() {
        curl -fsS --max-time 10 -X POST ${staged.healthUrl}/home-assistant/tv/on >/dev/null ||
          echo "htpc-night: could not ask for the TV" >&2
      }

      rm -f ${inputSeen}
      if [ "$timed" -eq 1 ]; then
        printf '%s %s\n' "$boot_id" "$started" > ${resuspendMarker}

        # The whole run is watched. Someone at the box must not sit in front of
        # a dark TV until the update finishes, so it comes on straight away.
        # Only real input: resuming re-adds devices, and that is not a person.
        # Not a `grep -q` pipeline: that waits for libinput to notice the pipe
        # closed, which it only does on the next event.
        (
          while read -r line; do
            if [[ $line =~ ^-?event[0-9]+[[:space:]]+(KEYBOARD_KEY|POINTER_|TOUCH_|GESTURE_|TABLET_) ]]; then
              echo "htpc-night: input seen: $line"
              touch ${inputSeen}
              # Now and not at the decision: htpc-update can reboot before that,
              # and the next boot must not put this person's box to sleep.
              rm -f ${resuspendMarker}
              tv_on
              exit 0
            fi
          done < <(stdbuf -oL libinput debug-events)
          echo "htpc-night: the input watcher stopped; input will not be noticed" >&2
        ) &
      else
        rm -f ${resuspendMarker}
      fi

      left() { echo $(( deadline - $(date +%s) )); }

      # Run a unit and report how it went, without letting it stop this script.
      # The client giving up leaves the unit running; it is a stuck unit that
      # this is here for.
      run_unit() {
        local seconds
        seconds=$(left)
        if [ "$seconds" -le 0 ]; then
          echo "htpc-night: out of time before $1" >&2
        elif ! timeout "$seconds" systemctl start "$1"; then
          echo "htpc-night: $1 did not succeed; carrying on to the decision" >&2
        fi
      }

      reboot_pending() {
        [ "$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
             org.freedesktop.login1.Manager PreparingForShutdown 2>/dev/null)" = "b true" ]
      }

      # The boot-time run and the transient one htpc-update detaches. Either can
      # end in a rollback with its own switch or reboot. The verify marker is not
      # the test: one with no watchdog behind it would never clear.
      watchdog_running() {
        [ "$(systemctl show -P ActiveState htpc-update-watchdog.service)" = activating ] ||
          [ -n "$(systemctl list-units --plain --no-legend --state=active,activating 'htpc-update-watchdog-run-*')" ]
      }

      ${updateInFlightFn}

      settle() {
        while { update_in_flight || watchdog_running; } && [ "$(date +%s)" -lt "$hard_deadline" ]; do
          sleep 2
        done
      }

      # The link can take some seconds to return from S3, and the fetch reads a
      # cache it cannot reach as "nothing published", which would lose the night
      # without a word. Any HTTP answer will do.
      network_deadline=$(( $(date +%s) + 60 ))
      until curl -s -o /dev/null --max-time 5 ${staged.cacheUrl}/ ||
            [ "$(date +%s)" -ge "$network_deadline" ]; do
        sleep 2
      done

      # On the boot after a reboot this joins the job already queued, which runs
      # after the boot's own watchdog. With someone at the box no update is
      # started. One already inside the fetch is left to finish: stopping that
      # unit could kill a switch halfway, which is what its protections are for.
      if [ ! -e ${inputSeen} ]; then
        run_unit htpc-update-fetch.service
      fi
      settle

      # The fetch stops early when the pointer is already staged, and
      # htpc-update's timer counts on a clock that stands still during sleep, so
      # a generation staged during the day would wait for ever. Guarded by the
      # link because with nothing staged htpc-update reports "none", which
      # would bury a "rolled-back" that just happened.
      if [ -L ${pendingRoot} ] && [ ! -e ${inputSeen} ] && ! reboot_pending; then
        run_unit htpc-update.service
        settle
      fi

      ${lib.optionalString config.roles.update-alerts.enable ''
        # Tell someone if updating has stopped or rolled back. Bounded (the unit
        # gives up at 30 s) and never a reason for the decision below to change:
        # a missing, failing or hanging alert is only logged.
        timeout 35 systemctl start htpc-update-alerts.service ||
          echo "htpc-night: the update alert check did not succeed; carrying on" >&2
      ''}
      decide() {
        local input=0 busy=0
        [ ! -e ${inputSeen} ] || input=1
        # A failed request reads as not busy, as it does for htpc-update.
        if [ "$(curl -fsS --max-time 5 ${staged.healthUrl}/system/activity 2>/dev/null |
                jq -r '.busy' 2>/dev/null)" = "true" ]; then
          busy=1
        fi
        TIMED=$timed INPUT_SEEN=$input BUSY=$busy REBOOT_PENDING=$1 htpc-night-decide
      }

      pending=0
      if reboot_pending; then pending=1; fi
      decision=$(decide "$pending")

      if [ "$decision" = keep-marker ]; then
        echo "htpc-night: a reboot is under way; the marker stays for the next boot"
        # Shutdown stops this unit long before this ends. Still being here means
        # the reboot did not happen, and the marker must not outlive that.
        sleep 120
        echo "htpc-night: the reboot did not happen" >&2
        decision=$(decide 0)
      fi

      echo "htpc-night: decided $decision"
      rm -f ${resuspendMarker}
      case "$decision" in
        suspend)
          if update_in_flight; then
            echo "htpc-night: an update is still under way; not suspending" >&2
            exit 1
          fi
          # A short timer: the default accuracy would let this slip by a minute.
          if ! systemd-run --quiet --collect --unit=htpc-night-suspend --on-active=2s \
               --timer-property=AccuracySec=100ms ${lib.getExe htpc-night-suspend}; then
            echo "htpc-night: could not schedule the suspend; asking from here" >&2
            ${lib.getExe htpc-night-suspend}
          fi
          ;;
        tv-on)
          tv_on
          ;;
      esac
    '';
  };
in
{
  options.roles.night-updates = {
    enable = lib.mkEnableOption "waking at night to update, and going back to sleep";

    wakeTime = lib.mkOption {
      type = lib.types.str;
      default = "03:30";
      description = ''
        HH:MM, in the machine's timezone. Keep it inside
        roles.staged-updates.activationWindow, and away from the hour the
        clocks change.
      '';
    };

    suspendCommand = lib.mkOption {
      type = lib.types.str;
      default = "${pkgs.systemd}/bin/systemctl suspend";
      description = ''
        How the box goes back to sleep. Only the nixosTest changes this, so a
        VM records the request and stays up to be looked at.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = staged.enable;
        message = "roles.night-updates runs the units of roles.staged-updates, which is not enabled";
      }
      {
        assertion = lib.match "([01][0-9]|2[0-3]):[0-5][0-9]" cfg.wakeTime != null;
        message = "roles.night-updates.wakeTime must be zero-padded HH:MM (got ${cfg.wakeTime})";
      }
    ];

    environment.systemPackages = [ htpc-night-decide ];

    systemd.tmpfiles.rules = [ "d ${runDir} 0755 root root -" ];

    # systemd is built here with SYSTEM_SLEEP_PATH=/etc/systemd/system-sleep.
    environment.etc."systemd/system-sleep/htpc-night".source = lib.getExe sleepHook;

    # Home Player's Sleep owns suspend; a Plasma idle timer would put the box to
    # sleep under a film it cannot see. System-wide, so it covers both accounts
    # and any added later. Nothing here stops the Sleep button, which goes to
    # logind directly.
    environment.etc."xdg/powerdevilrc".text =
      lib.concatMapStrings
        (profile: ''
          [${profile}][SuspendAndShutdown]
          AutoSuspendAction=0

        '')
        [
          "AC"
          "Battery"
          "LowBattery"
        ];

    systemd.timers.htpc-night = {
      description = "Wake the box at night to update it";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* ${cfg.wakeTime}:00";
        WakeSystem = true;
        AccuracySec = "1s";
        # A night missed while powered off is caught the next night. Catching up
        # at boot would put to sleep a box somebody has just turned on.
        Persistent = false;
      };
    };

    systemd.services.htpc-night = {
      description = "Update after a timed wake, then go back to sleep";
      # The timer comes due the moment the box thaws, in a race with the sleep
      # hook's `post`. A job ordered after the suspend that is still finishing
      # waits for it, so resumed-at is always this wake's. It starts nothing.
      after = [ "systemd-suspend.service" ];
      # See the long comment on systemd.services.htpc-update in
      # staged-updates.nix. This unit waits on a switch; it must not be one a
      # switch is willing to stop.
      restartIfChanged = false;
      unitConfig.X-StopOnRemoval = false;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe htpc-night;
        TimeoutStartSec = "30min";
        # The sleep hook stops a run on purpose. A oneshot otherwise counts that
        # as a failure.
        SuccessExitStatus = "SIGTERM";
      };
    };

    # The second half of a night whose update rebooted. Does nothing without
    # the marker. RemainAfterExit and restartIfChanged = false for the reason
    # given on htpc-update-watchdog.service: otherwise a switch starts this
    # again, and it must run once per boot. No ordering on the update units: the
    # script joins them itself, and being After= the fetch would deadlock the
    # switch that first introduces this unit, since that switch runs inside the
    # fetch and waits for this.
    systemd.services.htpc-night-after-boot = {
      description = "Go back to sleep after a reboot that happened during the night's update";
      wantedBy = [ "multi-user.target" ];
      restartIfChanged = false;
      stopIfChanged = false;
      unitConfig.X-StopOnRemoval = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${lib.getExe htpc-night} --after-boot";
        TimeoutStartSec = "30min";
        # As on htpc-night.service.
        SuccessExitStatus = "SIGTERM";
      };
    };
  };
}
