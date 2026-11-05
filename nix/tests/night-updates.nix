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
            "rm -f /run/fake-cache/pointers/machine",
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

    def night_finished(timeout=300):
        machine.wait_until_succeeds(
            "[ \"$(systemctl show -P ActiveState htpc-night.service)\" != activating ]"
            " && ! systemctl list-jobs --no-legend | grep -q htpc-night.service",
            timeout=timeout,
        )
        machine.fail("systemctl is-failed --quiet htpc-night.service")

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
        assert decide(TIMED=1, BUSY=1) == "stay-awake"
        assert decide(TIMED=1, REBOOT_PENDING=1) == "keep-marker"
        assert decide(TIMED=0) == "stay-awake"
        # A person is the answer to anything else: nobody suspends under them,
        # on this boot or, through the marker, on the next.
        assert decide(TIMED=1, INPUT_SEEN=1, REBOOT_PENDING=1) == "tv-on"
        assert decide(TIMED=1, BUSY=1, REBOOT_PENDING=1) == "stay-awake"
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

    with subtest("busy: stays awake"):
        reset()
        machine.succeed("echo true > /run/fake-backend/busy")
        timed_wake()
        run_night()
        assert suspends() == []
        assert tv_on_calls() == 0

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
