# The box sleeps, wakes itself at night, updates, and goes back to sleep with
# the TV off. A VM cannot be relied on to do real S3, so the suspend is a
# recording command and the wake is the sleep hook run by hand; everything from
# the timer's elapse to the request to suspend is the real thing, including the
# switch and a reboot the update asks for.
{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "htpc-night-updates";

  nodes.machine =
    { pkgs, lib, ... }:
    let
      # Says what was still in flight when suspend was asked for, because the
      # order is the point. On /var: a request made after a reboot has to be
      # readable, and so does one from before it.
      fakeSuspend = pkgs.writeShellScript "fake-suspend" ''
        if [ -e /var/lib/fake-suspend-fails ]; then
          ${pkgs.coreutils}/bin/rm /var/lib/fake-suspend-fails
          exit 1
        fi
        ${pkgs.systemd}/bin/systemctl show -P NextElapseUSecRealtime htpc-night.timer \
          > /var/lib/fake-suspend-next
        ${pkgs.systemd}/bin/systemctl show -P ActiveState htpc-night.service \
          > /var/lib/fake-suspend-unit
        pending=no
        marker=no
        [ -e /var/lib/htpc-update/verify-after-reboot ] && pending=yes
        [ -e /var/lib/htpc-update/resuspend-after-boot ] && marker=yes
        echo "suspend watchdog-pending=$pending marker=$marker" >> /var/lib/fake-suspend
      '';
    in
    {
      imports = [
        ../roles/staged-updates.nix
        ../roles/night-updates.nix
        ../roles/update-alerts.nix
      ];

      roles.staged-updates = {
        enable = true;
        requireSignatures = false;
        requireKioskUnit = false;
        # Long enough for the test to look while a watchdog is in flight.
        watchdogSeconds = 60;
        activationWindow = {
          start = "03:30";
          end = "05:30";
        };
        cacheUrl = "http://127.0.0.1:8081";
      };

      roles.update-alerts = {
        enable = true;
        notifyService = "notify.mobile_app_pixel_8";
        haUrl = "http://127.0.0.1:8123";
        environmentFile = "/run/ha-env";
      };

      systemd.services.fake-ha = {
        description = "Stand-in for Home Assistant's notify API";
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${./fake-ha.py}";
      };

      roles.night-updates = {
        enable = true;
        suspendCommand = "${fakeSuspend}";
      };

      # As in staged-updates.nix: this test calls switch-to-configuration, and
      # the VM boots from the store, so there is no boot loader to install.
      system.switch.enable = true;
      boot.loader.grub.enable = false;
      virtualisation.cores = 4;
      time.timeZone = "Europe/Stockholm";
      nix.settings.experimental-features = [ "nix-command" ];

      # kreadconfig6 reads the config the way Plasma does.
      environment.systemPackages = [ pkgs.kdePackages.kconfig ];

      systemd.tmpfiles.rules = [
        "d /run/fake-cache/pointers 0755 root root -"
        "d /run/fake-backend 0755 root root -"
        "d /run/fake-ha 0755 root root -"
        "f+ /run/ha-env 0600 root root - HA_TOKEN=test-ha-token"
        "f /run/fake-backend/busy 0644 root root - false"
        "f /run/fake-backend/healthy 0644 root root - true"
        "f /run/fake-backend/tv-on 0644 root root -"
      ];

      systemd.services.fake-cache = {
        description = "Stand-in for the binary cache's pointer directory";
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8081 --bind 127.0.0.1 --directory /run/fake-cache";
      };

      systemd.services.fake-home-player = {
        description = "Stand-in for the home-player backend";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        # On the boot after a kernel update, a backend that takes a moment
        # means the watchdog is still in flight when the night job looks.
        serviceConfig.ExecStartPre = pkgs.writeShellScript "slow-backend" ''
          if [ -e /var/lib/test-slow-backend ]; then ${pkgs.coreutils}/bin/sleep 12; fi
        '';
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${./fake-home-player.py}";
      };

      # Looks like a switch from outside; started by the subtest that needs one.
      systemd.services.fake-switch.serviceConfig.ExecStart =
        pkgs.writeShellScript "switch-to-configuration" "${pkgs.coreutils}/bin/sleep 600";

      # This VM always boots the kernel and initrd QEMU was handed, so a reboot
      # for a new initrd lands on the old one. Without this, htpc-update would
      # see the pending generation again and reboot for ever. It also restores
      # the clock, because QEMU's RTC restarts from the host's: before the
      # timers, so moving it does not make one elapse.
      systemd.services.test-reboot-landed = {
        description = "Make a reboot in this VM look as it does on the real box";
        wantedBy = [ "sysinit.target" ];
        before = [
          "sysinit.target"
          "timers.target"
        ];
        after = [ "local-fs.target" ];
        unitConfig.DefaultDependencies = false;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "test-reboot-landed" ''
            ${pkgs.coreutils}/bin/rm -f /nix/var/nix/gcroots/htpc-pending
            if [ -e /var/lib/test-clock ]; then
              ${pkgs.coreutils}/bin/date -s "@$(${pkgs.coreutils}/bin/cat /var/lib/test-clock)"
            fi
          '';
        };
      };

      # An ordinary update. Moving suspendCommand changes htpc-night.service's
      # own ExecStart, so a switch sees the unit it is running inside as
      # changed, which is the case restartIfChanged = false exists for.
      specialisation.next.configuration = {
        environment.etc."htpc-generation".text = "2";
        roles.night-updates.suspendCommand = lib.mkForce "${fakeSuspend} next";
      };

      # An update that needs a reboot: a different initrd is enough, and costs
      # far less to build than a different kernel.
      specialisation.reboots.configuration = {
        boot.initrd.systemd.contents."/etc/this-initrd-differs".text = "yes";
      };
    };

  testScript = ''
    import json

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_open_port(9600)
    machine.execute("systemctl stop systemd-timesyncd.service")

    base = machine.succeed("readlink -f /run/current-system").strip()
    nxt = machine.succeed("readlink -f /run/current-system/specialisation/next").strip()
    reboots = machine.succeed("readlink -f /run/current-system/specialisation/reboots").strip()
    profile = "/nix/var/nix/profiles/system"
    state_dir = "/var/lib/htpc-update"
    marker = f"{state_dir}/resuspend-after-boot"
    verify = f"{state_dir}/verify-after-reboot"
    run_dir = "/run/htpc-night"
    hook = "/etc/systemd/system-sleep/htpc-night"

    def decide(**env):
        assignments = " ".join(f"{k}={v}" for k, v in env.items())
        return machine.succeed(f"{assignments} htpc-night-decide").strip()

    def set_clock(hhmm):
        machine.succeed(f"date -s \"$(date +%F) {hhmm}:00\"")
        assert machine.succeed("date +%H:%M").strip() == hhmm, hhmm

    def suspends():
        return machine.succeed("cat /var/lib/fake-suspend 2>/dev/null || true").splitlines()

    def tv_on_calls():
        return len(machine.succeed("cat /run/fake-backend/tv-on").splitlines())

    def night_state():
        return machine.succeed("systemctl show -P ActiveState htpc-night.service").strip()

    def reset():
        machine.succeed(
            "rm -f /var/lib/fake-suspend",
            ": > /run/fake-backend/tv-on",
            "echo false > /run/fake-backend/busy",
            "echo true > /run/fake-backend/healthy",
            f"rm -f {marker}",
            "rm -f /run/fake-cache/pointers/machine /nix/var/nix/gcroots/htpc-pending",
            "systemctl start fake-cache.service fake-home-player.service",
        )
        machine.wait_for_open_port(9600)
        machine.wait_for_open_port(8081)

    def timed_wake():
        # The hook, as systemd-sleep runs it, at the moment the timer was due.
        machine.succeed(f"date +%s > {run_dir}/scheduled-wake", f"{hook} post suspend")

    def start_night():
        # Several starts in a few seconds trip systemd's start-rate limit,
        # which is nothing to do with what is under test.
        machine.succeed(
            "systemctl reset-failed htpc-night.service htpc-update-fetch.service htpc-update.service"
        )
        machine.succeed("systemctl start --no-block htpc-night.service")

    def night_finished(timeout=300, check=True):
        machine.wait_until_succeeds(
            "[ \"$(systemctl show -P ActiveState htpc-night.service)\" != activating ]"
            " && ! systemctl list-jobs --no-legend | grep -q htpc-night.service",
            timeout=timeout,
        )
        # The suspend is asked for from outside the unit, a moment after it ends.
        machine.wait_until_fails(
            "systemctl list-units --plain --no-legend 'htpc-night-suspend*' | grep -q .",
            timeout=30,
        )
        if check:
            machine.fail("systemctl is-failed --quiet htpc-night.service")

    def fire_from_timer():
        # Only a run the timer started puts the timer in its running state, with
        # no next elapse. One started by hand leaves it waiting, and a test of
        # that would pass against the bug.
        due = machine.succeed(
            "systemctl show -P NextElapseUSecRealtime --timestamp=unix htpc-night.timer"
        ).strip().lstrip("@")
        machine.succeed(
            "systemctl reset-failed htpc-night.service htpc-update-fetch.service htpc-update.service",
            f"date -s @{int(due) - 3}",
            f"echo {due} > {run_dir}/scheduled-wake",
            f"{hook} post suspend",
        )
        machine.wait_until_succeeds(
            "[ \"$(systemctl show -P ActiveState htpc-night.service)\" = activating ]", timeout=30
        )
        assert machine.succeed("systemctl show -P SubState htpc-night.timer").strip() == "running"
        assert not machine.succeed(
            "systemctl show -P NextElapseUSecRealtime htpc-night.timer"
        ).strip(), "the premise is gone: a timer with a running job still has a next elapse"

    def run_night():
        start_night()
        night_finished()

    def back_to_base():
        machine.succeed(
            f"nix-env -p {profile} --set {base}",
            f"{base}/bin/switch-to-configuration switch",
            f"rm -f {verify} /nix/var/nix/gcroots/htpc-pending {state_dir}/state.json",
            f": > {state_dir}/bad-revisions",
        )

    with subtest("the decision"):
        assert decide(TIMED=1) == "suspend"
        assert decide(TIMED=1, INPUT_SEEN=1) == "tv-on"
        # Nobody touched a box the timer woke, so whatever the backend says is
        # left over from before it slept: it goes back to sleep regardless.
        assert decide(TIMED=1, BUSY=1) == "suspend"
        assert decide(TIMED=1, REBOOT_PENDING=1) == "keep-marker"
        assert decide(TIMED=0) == "stay-awake"
        # A person is the answer to anything else: nobody suspends under them,
        # on this boot or, through the marker, on the next.
        assert decide(TIMED=1, INPUT_SEEN=1, REBOOT_PENDING=1) == "tv-on"
        assert decide(TIMED=1, BUSY=1, REBOOT_PENDING=1) == "keep-marker"
        assert decide(TIMED=1, INPUT_SEEN=1, BUSY=1) == "tv-on"
        assert decide(TIMED=0, INPUT_SEEN=1, BUSY=1, REBOOT_PENDING=1) == "stay-awake"

    with subtest("the timer wakes the box, at the agreed time"):
        unit = machine.succeed("systemctl cat htpc-night.timer")
        for line in (
            "OnCalendar=*-*-* 03:30:00",
            "WakeSystem=true",
            "AccuracySec=1s",
            "Persistent=false",
        ):
            assert line in unit, f"{line} missing from {unit}"

    with subtest("Plasma does not suspend on its own; Home Player's Sleep still can"):
        assert (
            machine.succeed(
                "HOME=/tmp XDG_CONFIG_DIRS=/etc/xdg kreadconfig6 --file powerdevilrc"
                " --group AC --group SuspendAndShutdown --key AutoSuspendAction"
            ).strip()
            == "0"
        )
        machine.fail("systemctl is-enabled suspend.target | grep -q masked")

    with subtest("the sleep hook leaves the shell a plain, readable epoch"):
        machine.succeed(f"{hook} pre suspend")
        raw = machine.succeed(f"su -s /bin/sh nobody -c 'cat {run_dir}/scheduled-wake'")
        assert raw.strip().isdigit(), f"not a plain epoch: {raw!r}"
        assert machine.succeed(f"stat -c %a {run_dir}/scheduled-wake").strip() == "644"
        assert machine.succeed(f"stat -c %a {run_dir}").strip() == "755"
        next_run = int(raw)
        assert machine.succeed(f"date -d @{next_run} +%H:%M:%S").strip() == "03:30:00"
        assert next_run > int(machine.succeed("date +%s"))
        planned = machine.succeed(
            "systemctl show -P NextElapseUSecRealtime --timestamp=unix htpc-night.timer"
        ).strip()
        assert planned == f"@{next_run}", f"the timer plans {planned}, the hook said {next_run}"

        now = int(machine.succeed("date +%s"))
        machine.succeed(f"{hook} post suspend")
        assert int(machine.succeed(f"cat {run_dir}/resumed-at")) >= now
        assert machine.succeed(f"stat -c %a {run_dir}/resumed-at").strip() == "644"

    with subtest("the timer fires a real run, and a box that was awake stays awake"):
        reset()
        machine.succeed(f"date -d '-1 hour' +%s > {run_dir}/resumed-at")
        # Forward to the elapse it already has planned, as the hook just read it.
        machine.succeed(f"date -s @{next_run - 3}")
        machine.wait_until_succeeds(
            "journalctl -u htpc-night.service --grep 'decided stay-awake'", timeout=120
        )
        night_finished()
        assert suspends() == []
        assert tv_on_calls() == 0
        machine.fail(f"test -e {marker}")

    with subtest("Sleep during a run: the run stops, tomorrow is scheduled, no marker"):
        reset()
        # With the cache down the run stays in its network wait.
        machine.succeed("systemctl stop fake-cache.service")
        fire_from_timer()
        machine.wait_until_succeeds(f"test -e {marker}", timeout=30)

        now = int(machine.succeed("date +%s"))
        machine.succeed(f"{hook} pre suspend")
        scheduled = int(machine.succeed(f"cat {run_dir}/scheduled-wake"))
        assert machine.succeed(f"date -d @{scheduled} +%H:%M:%S").strip() == "03:30:00"
        assert now < scheduled <= now + 25 * 3600, (now, scheduled)
        # Stopped, the timer has its next elapse, which is what arms the alarm.
        assert machine.succeed(
            "systemctl show -P NextElapseUSecRealtime htpc-night.timer"
        ).strip(), "the timer has no next elapse to wake the box"
        assert night_state() != "activating", "the run outlived the Sleep"
        machine.fail("systemctl is-failed --quiet htpc-night.service")
        machine.fail(f"test -e {marker}")
        assert suspends() == []

    with subtest("the run's own suspend comes after the unit, so the timer is armed"):
        reset()
        # Long enough to see the timer's state during the run.
        machine.succeed(
            "mkdir -p /run/systemd/system/htpc-update-fetch.service.d",
            "printf '[Service]\\nExecStart=\\nExecStart=${pkgs.coreutils}/bin/sleep 5\\n'"
            " > /run/systemd/system/htpc-update-fetch.service.d/slow.conf",
            "systemctl daemon-reload",
            "rm -f /var/lib/fake-suspend-next /var/lib/fake-suspend-unit",
        )
        fire_from_timer()
        night_finished()
        machine.succeed(
            "rm -r /run/systemd/system/htpc-update-fetch.service.d", "systemctl daemon-reload"
        )
        assert len(suspends()) == 1, suspends()
        unit_state = machine.succeed("cat /var/lib/fake-suspend-unit").strip()
        assert unit_state != "activating", "suspend was asked for from inside the run"
        assert machine.succeed("cat /var/lib/fake-suspend-next").strip(), (
            "the timer had no next elapse when suspend was asked for"
        )

    with subtest("a failed suspend is tried once more, and says so"):
        reset()
        machine.succeed("touch /var/lib/fake-suspend-fails")
        timed_wake()
        run_night()
        assert len(suspends()) == 1, suspends()
        machine.succeed("journalctl --grep 'suspend failed; trying once more'")

    with subtest("a person's Sleep cancels the run's own suspend, pending or retrying"):
        reset()
        machine.succeed(
            "systemd-run --collect --unit=htpc-night-suspend --on-active=60s ${pkgs.coreutils}/bin/true"
        )
        machine.succeed(f"{hook} pre suspend")
        machine.fail("systemctl list-units --plain --no-legend 'htpc-night-suspend*' | grep -q .")

        # In the retry's wait, which the fake's failure marks.
        machine.succeed("touch /var/lib/fake-suspend-fails")
        timed_wake()
        start_night()
        machine.wait_until_succeeds("! test -e /var/lib/fake-suspend-fails", timeout=30)
        machine.succeed(f"{hook} pre suspend")
        machine.fail("systemctl list-units --plain --no-legend 'htpc-night-suspend*' | grep -q .")
        machine.sleep(7)
        assert suspends() == [], "the retry put the box to sleep after a person's Sleep"

    with subtest("an update that starts in the gap holds back the suspend"):
        reset()
        machine.succeed("touch /var/lib/fake-suspend-fails")
        timed_wake()
        start_night()
        machine.wait_until_succeeds("! test -e /var/lib/fake-suspend-fails", timeout=30)
        machine.succeed("systemctl start fake-switch.service")
        machine.sleep(8)
        assert suspends() == [], "suspended under an update that started in the gap"
        machine.succeed("systemctl stop fake-switch.service")
        night_finished()
        assert len(suspends()) == 1, suspends()

    # Every run below is started by hand; a clock moved by a test must not fire
    # one under it.
    machine.succeed("systemctl stop htpc-night.timer")
    set_clock("04:00")

    with subtest("a stopped timer leaves no schedule, not a wrong one"):
        machine.succeed(f"{hook} pre suspend")
        machine.fail(f"test -e {run_dir}/scheduled-wake")

    with subtest("timed wake, nothing else: back to sleep, TV untouched"):
        reset()
        timed_wake()
        run_night()
        assert suspends() == ["suspend watchdog-pending=no marker=no"], suspends()
        assert tv_on_calls() == 0

    def ha_calls():
        return len(machine.succeed("cat /run/fake-ha/calls 2>/dev/null || true").splitlines())

    with subtest("the run checks for failed updates, and what it finds changes nothing"):
        reset()
        machine.succeed("rm -f /run/fake-ha/calls /run/fake-ha/hang /run/fake-ha/refuse")
        machine.succeed(f"rm -f {state_dir}/alerts-sent")
        bad = "/nix/store/00000000000000000000000000000000-bad-one"
        machine.succeed(f"echo {bad} > {state_dir}/bad-revisions")
        machine.succeed(f"echo '{{\"reason\":\"none\",\"staged_at\":0}}' > {state_dir}/state.json")
        timed_wake()
        run_night()
        assert ha_calls() == 1, f"expected one alert from the run, Home Assistant was told {ha_calls()} time(s)"
        assert suspends() == ["suspend watchdog-pending=no marker=no"], suspends()

        # A check that cannot even start is no reason to stay awake.
        reset()
        # (Not `mask`: a unit file under /etc outranks a runtime mask.)
        dropin = "/run/systemd/system/htpc-update-alerts.service.d"
        machine.succeed(
            f"echo {bad}-2 >> {state_dir}/bad-revisions",
            f"mkdir -p {dropin}",
            f"printf '[Service]\\nExecStart=\\nExecStart=${pkgs.coreutils}/bin/false\\n' > {dropin}/fail.conf",
            "systemctl daemon-reload",
        )
        timed_wake()
        run_night()
        machine.succeed(f"rm -rf {dropin}", "systemctl daemon-reload")
        assert "did not succeed" in machine.succeed("journalctl -u htpc-night.service --no-pager | tail -n 40"), "the failing alert was not seen by the run"
        assert ha_calls() == 1, f"expected one alert from the run, Home Assistant was told {ha_calls()} time(s)"
        assert suspends() == ["suspend watchdog-pending=no marker=no"], suspends()

        # Nor is one that hangs: Home Assistant is given ten seconds, not sixty.
        reset()
        machine.succeed("touch /run/fake-ha/hang")
        timed_wake()
        before = int(machine.succeed("date +%s"))
        run_night()
        took = int(machine.succeed("date +%s")) - before
        machine.succeed("rm /run/fake-ha/hang", "systemctl restart fake-ha.service")
        assert took < 45, took
        assert suspends() == ["suspend watchdog-pending=no marker=no"], suspends()
        machine.succeed(f": > {state_dir}/bad-revisions")

    with subtest("woken just before the timer: that was a person, it stays awake"):
        reset()
        machine.succeed(
            f"date +%s > {run_dir}/scheduled-wake",
            f"date -d '-60 seconds' +%s > {run_dir}/resumed-at",
        )
        run_night()
        assert suspends() == []

    with subtest("an old resume is not this wake"):
        reset()
        machine.succeed(
            f"date -d '-200 seconds' +%s > {run_dir}/scheduled-wake",
            f"date -d '-200 seconds' +%s > {run_dir}/resumed-at",
        )
        run_night()
        assert suspends() == []

    with subtest("busy, no input, timed wake: no update, back to sleep"):
        # A game left running on the VM or a film left paused, from before the
        # box slept. Nobody is there, so it sleeps, and it updates nothing.
        reset()
        machine.succeed(
            f"nix-env -p {profile} --set {base}",
            f"htpc-stage --no-activate {nxt}",
            "echo true > /run/fake-backend/busy",
        )
        timed_wake()
        run_night()
        assert suspends() == ["suspend watchdog-pending=no marker=no"], suspends()
        assert tv_on_calls() == 0
        assert machine.succeed("readlink -f /run/current-system").strip() == base, "updated while busy"
        state = json.loads(machine.succeed(f"cat {state_dir}/state.json"))
        assert state["reason"] == "busy", state

    with subtest("a backend that does not answer is not busy"):
        reset()
        machine.succeed("systemctl stop fake-home-player.service")
        timed_wake()
        run_night()
        assert len(suspends()) == 1, suspends()

    with subtest("input during the run: TV on at once, stays awake"):
        reset()
        # With the cache down the run waits for the network for a minute, so
        # the key lands in the middle of it.
        machine.succeed("systemctl stop fake-cache.service")
        timed_wake()
        start_night()
        machine.wait_until_succeeds("pgrep -f 'libinput.*debug-events'", timeout=30)
        # libinput opens its devices a moment after it starts.
        machine.sleep(3)
        machine.send_key("a")
        machine.wait_until_succeeds("test -s /run/fake-backend/tv-on", timeout=20)
        assert night_state() == "activating", "the TV came on only at the end of the run"
        night_finished()
        assert suspends() == []
        machine.fail(f"test -e {marker}")

    with subtest("a failed or unreachable fetch still returns to sleep"):
        reset()
        machine.succeed("systemctl stop fake-cache.service")
        timed_wake()
        run_night()
        assert len(suspends()) == 1, suspends()

        reset()
        # htpc-update-fetch refuses this outright and fails.
        machine.succeed("echo not-a-store-path > /run/fake-cache/pointers/machine")
        timed_wake()
        run_night()
        machine.succeed("systemctl is-failed --quiet htpc-update-fetch.service")
        assert len(suspends()) == 1, suspends()

    with subtest("a fetch that never ends still returns to sleep before the unit times out"):
        reset()
        machine.succeed(
            "mkdir -p /run/systemd/system/htpc-update-fetch.service.d /run/systemd/system/htpc-night.service.d",
            "printf '[Service]\\nExecStart=\\nExecStart=${pkgs.coreutils}/bin/sleep 600\\n'"
            " > /run/systemd/system/htpc-update-fetch.service.d/hang.conf",
            "printf '[Service]\\nEnvironment=HTPC_NIGHT_BUDGET_SECONDS=10\\n'"
            " > /run/systemd/system/htpc-night.service.d/budget.conf",
            "systemctl daemon-reload",
        )
        timed_wake()
        run_night()
        assert len(suspends()) == 1, suspends()
        machine.succeed(
            "systemctl stop htpc-update-fetch.service",
            "rm -r /run/systemd/system/htpc-update-fetch.service.d /run/systemd/system/htpc-night.service.d",
            "systemctl daemon-reload",
        )

    with subtest("the budget running out does not suspend under htpc-update"):
        reset()
        machine.succeed(
            f"nix-env -p {profile} --set {base}",
            f"htpc-stage --no-activate {nxt}",
            "mkdir -p /run/systemd/system/htpc-update.service.d /run/systemd/system/htpc-night.service.d",
            "printf '[Service]\\nExecStart=\\nExecStart=${pkgs.coreutils}/bin/sleep 600\\n'"
            " > /run/systemd/system/htpc-update.service.d/hang.conf",
            "printf '[Service]\\nEnvironment=HTPC_NIGHT_BUDGET_SECONDS=5\\n'"
            " > /run/systemd/system/htpc-night.service.d/budget.conf",
            "systemctl daemon-reload",
        )
        timed_wake()
        start_night()
        machine.wait_until_succeeds(
            "[ \"$(systemctl show -P ActiveState htpc-update.service)\" = activating ]", timeout=30
        )
        machine.sleep(12)
        assert suspends() == [], "suspended under htpc-update"
        assert night_state() == "activating"
        machine.succeed("systemctl stop htpc-update.service")
        night_finished()
        assert len(suspends()) == 1, suspends()
        machine.succeed(
            "rm -r /run/systemd/system/htpc-update.service.d",
            "rm -f /nix/var/nix/gcroots/htpc-pending",
            "systemctl daemon-reload",
        )

    with subtest("a switch that never ends: no suspend, and the unit says so"):
        # The fetch runs its switch inside its own unit, so only the process shows.
        reset()
        machine.succeed("systemctl start fake-switch.service")
        timed_wake()
        start_night()
        night_finished(check=False)
        machine.succeed("systemctl is-failed --quiet htpc-night.service")
        machine.succeed("journalctl -u htpc-night.service --grep 'still under way; not suspending'")
        assert suspends() == [], "suspended under a switch"
        machine.succeed(
            "systemctl stop fake-switch.service",
            "rm -r /run/systemd/system/htpc-night.service.d",
            "systemctl daemon-reload",
        )

    with subtest("the switch does not kill the run, which waits out the watchdog"):
        # Proves the premise: this switch changes the unit it runs inside.
        old_def = machine.succeed(f"cat {base}/etc/systemd/system/htpc-night.service")
        new_def = machine.succeed(f"cat {nxt}/etc/systemd/system/htpc-night.service")
        assert old_def != new_def, "the generations agree, so this cannot see the bug"
        assert "X-RestartIfChanged=false" in new_def, new_def
        assert "X-StopOnRemoval=false" in new_def, new_def

        reset()
        # Staged earlier, when the window was shut, and the cache has no
        # pointer: the fetch alone would leave this waiting for a timer that
        # does not get to run while the box sleeps.
        machine.succeed(
            f"nix-env -p {profile} --set {base}",
            f"htpc-stage --no-activate {nxt}",
            "echo false > /run/fake-backend/healthy",
        )
        timed_wake()
        start_night()
        machine.wait_until_succeeds(
            f"[ \"$(readlink -f /run/current-system)\" = {nxt} ]", timeout=240
        )
        machine.wait_until_succeeds(f"test -e {verify}", timeout=30)
        # The switch has returned and the watchdog is polling.
        machine.wait_until_succeeds("systemctl list-units --plain --no-legend 'htpc-update-watchdog-run-*' | grep -q .", timeout=60)
        machine.sleep(10)
        assert suspends() == [], "suspended under an in-flight watchdog"
        assert night_state() == "activating"
        machine.succeed("echo true > /run/fake-backend/healthy")
        night_finished()
        assert suspends() == ["suspend watchdog-pending=no marker=no"], suspends()
        assert machine.succeed("cat /etc/htpc-generation").strip() == "2"
        assert tv_on_calls() == 0

    with subtest("a failed rollback still returns to sleep"):
        back_to_base()
        reset()
        # With no earlier generation there is nothing to roll back to.
        machine.succeed(
            f"rm -f {profile} {profile}-*-link",
            f"htpc-stage --no-activate {nxt}",
            "echo false > /run/fake-backend/healthy",
        )
        timed_wake()
        run_night()
        state = json.loads(machine.succeed(f"cat {state_dir}/state.json"))
        assert state["reason"] == "rollback-failed", state
        assert suspends() == ["suspend watchdog-pending=no marker=no"], suspends()
        assert tv_on_calls() == 0

    def read_state():
        return json.loads(machine.succeed(f"cat {state_dir}/state.json"))

    def next_night():
        # A day later, 04:00, with a build the nixhost made a moment ago.
        machine.succeed(
            "date -s \"$(date -d '+1 day' +%F) 04:00:00\"",
            "date +%s > /run/fake-cache/pointers/machine.last-success",
        )

    def no_alerts_yet():
        machine.succeed(
            "rm -f /run/fake-ha/calls",
            f"rm -f {state_dir}/state.json {state_dir}/alerts-sent {state_dir}/alerts-stale-*"
            f" {state_dir}/staged-at {state_dir}/untaken-since",
            f": > {state_dir}/bad-revisions",
        )

    def no_notice(state):
        # Home Player's rule (backend/home_player/main.py, _update_notice).
        assert state["reason"] not in ("rollback-failed", "bad"), state
        assert not state.get("rolled_back_at"), state
        for key in ("build_age_seconds", "age_seconds"):
            age = state.get(key)
            assert not (isinstance(age, int) and age >= 3 * 86400), (key, state)

    with subtest("activated, then three nights with nothing new: no alert, no notice"):
        back_to_base()
        # The switch starts the timer again, and the days moved below would
        # fire it under these runs.
        machine.succeed("systemctl stop htpc-night.timer")
        reset()
        no_alerts_yet()
        set_clock("04:00")
        machine.succeed(
            f"htpc-stage --no-activate {nxt}",
            f"echo {nxt} > /run/fake-cache/pointers/machine",
            "date +%s > /run/fake-cache/pointers/machine.last-success",
        )
        timed_wake()
        run_night()
        assert machine.succeed("readlink -f /run/current-system").strip() == nxt
        assert read_state()["age_seconds"] == 0, read_state()
        for night in range(1, 4):
            next_night()
            # reset() takes the pointer away; the cache still names nxt.
            machine.succeed(f"echo {nxt} > /run/fake-cache/pointers/machine")
            timed_wake()
            run_night()
            state = read_state()
            assert ha_calls() == 0, (night, machine.succeed("cat /run/fake-ha/calls"))
            no_notice(state)
            assert state["age_seconds"] == 0, (night, state)

    with subtest("a pointer the box cannot take alerts once, after 3 nights"):
        # Or the switch below starts the fetch, which fails on it.
        machine.succeed("rm -f /run/fake-cache/pointers/machine")
        back_to_base()
        machine.succeed("systemctl stop htpc-night.timer")
        reset()
        no_alerts_yet()
        set_clock("04:00")
        # Published but not in the cache: the cache answers, the fetch fails.
        missing = "/nix/store/" + "3" * 32 + "-nixos-system-machine-missing"

        def night_with_missing_pointer():
            machine.succeed(
                f"echo {missing} > /run/fake-cache/pointers/machine",
                "date +%s > /run/fake-cache/pointers/machine.last-success",
            )
            timed_wake()
            run_night()
            machine.succeed("systemctl is-failed --quiet htpc-update-fetch.service")

        night_with_missing_pointer()
        for night in range(1, 3):
            next_night()
            night_with_missing_pointer()
            assert ha_calls() == 0, night
            assert read_state()["age_seconds"] < 3 * 86400, read_state()
        next_night()
        night_with_missing_pointer()
        assert ha_calls() == 1, machine.succeed("cat /run/fake-ha/calls")
        assert "waiting for 3 nights" in machine.succeed("cat /run/fake-ha/calls")
        assert read_state()["age_seconds"] >= 3 * 86400, read_state()
        next_night()
        night_with_missing_pointer()
        assert ha_calls() == 1, machine.succeed("cat /run/fake-ha/calls")
        no_alerts_yet()
        machine.succeed("rm -f /run/fake-cache/pointers/machine")

    with subtest("a stale marker does not put a freshly booted box to sleep"):
        back_to_base()
        reset()
        machine.succeed(
            f"echo old-boot-id $(date -d '-2 hours' +%s) > {marker}",
            "date +%s > /var/lib/test-clock",
        )
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("htpc-night-after-boot.service")
        assert suspends() == []
        machine.fail(f"test -e {marker}")

    with subtest("a marker from this boot is left to the run that wrote it"):
        machine.succeed(
            "cat /proc/sys/kernel/random/boot_id | tr -d '\\n' > /tmp/id",
            f"echo $(cat /tmp/id) $(date +%s) > {marker}",
            "systemctl restart htpc-night-after-boot.service",
        )
        assert suspends() == []
        machine.succeed(f"test -e {marker}", f"rm {marker}")

    with subtest("input, then a reboot: no update starts, and the next boot stays awake"):
        machine.succeed("systemctl stop htpc-night.timer")
        machine.execute("systemctl stop systemd-timesyncd.service")
        reset()
        set_clock("04:00")
        machine.succeed(
            f"nix-env -p {profile} --set {base}",
            f"htpc-stage --no-activate {reboots}",
            "systemctl stop fake-cache.service",
        )
        timed_wake()
        start_night()
        machine.wait_until_succeeds("pgrep -f 'libinput.*debug-events'", timeout=30)
        machine.sleep(3)
        machine.send_key("a")
        machine.wait_until_succeeds("test -s /run/fake-backend/tv-on", timeout=20)
        # At once, not at the decision: a reboot can come before that.
        machine.fail(f"test -e {marker}")
        night_finished()
        assert suspends() == []
        assert machine.succeed(f"readlink -f {profile}").strip() == base, "updated under a person"

        machine.succeed("date +%s > /var/lib/test-clock")
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("htpc-night-after-boot.service")
        assert suspends() == [], "put to sleep on the boot after someone used it"
        machine.fail(f"test -e {marker}")

    with subtest("a reboot during the run: asleep again once the watchdog is done"):
        machine.succeed("systemctl stop htpc-night.timer")
        machine.execute("systemctl stop systemd-timesyncd.service")
        reset()
        set_clock("04:00")
        machine.succeed(
            f"nix-env -p {profile} --set {base}",
            f"htpc-stage --no-activate {reboots}",
            "touch /var/lib/test-slow-backend",
            "date -d '+1 minute' +%s > /var/lib/test-clock",
        )
        # Plasma holds one of these on the real box. It keeps the reboot from
        # starting for a few seconds, which is when the run has to see it coming
        # rather than being stopped before it looks.
        machine.succeed(
            "systemd-run --unit=hold-shutdown --collect systemd-inhibit --what=shutdown"
            " --mode=delay --who=test --why=test ${pkgs.coreutils}/bin/sleep 600"
        )
        machine.wait_until_succeeds("systemd-inhibit --list | grep -q test", timeout=10)
        timed_wake()
        start_night()
        machine.wait_for_shutdown()
        machine.start()
        machine.wait_until_succeeds("test -s /var/lib/fake-suspend", timeout=300)
        machine.succeed("rm /var/lib/test-slow-backend")
        machine.succeed("journalctl -b -1 -u htpc-night.service --grep 'a reboot is under way'")
        # The update's own verify marker was still there when the box came up,
        # and suspending under it would be the bug.
        assert suspends() == ["suspend watchdog-pending=no marker=no"], suspends()
        assert tv_on_calls() == 0
        assert machine.succeed(f"readlink -f {profile}").strip() == reboots
        machine.fail(f"test -e {marker}")
        machine.fail(f"test -e {verify}")
  '';
}
