# Boot a VM, stage a second generation, and assert the four things the policy
# exists to get right: busy means nothing happens, idle means it activates,
# an unhealthy backend means it rolls back *and* marks the revision bad so
# the timer does not retry it every fifteen minutes -- and an update that
# changes this role's OWN units does not make switch-to-configuration stop the
# unit it is running inside.
#
# That last one is why the specialisation below changes a
# roles.staged-updates option and not only a file in /etc. An earlier version
# changed /etc/htpc-generation alone, so no unit definition ever differed
# between the two generations and the whole restartIfChanged class of bug --
# the one that silently half-activates an update and leaves every recorded
# state lying about it -- was invisible to this test by construction.
{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "htpc-staged-updates";

  nodes.machine =
    {
      pkgs,
      lib,
      config,
      ...
    }:
    {
      imports = [
        ../roles/staged-updates.nix
        ../roles/update-alerts.nix
      ];

      roles.staged-updates = {
        enable = true;
        # A test VM has no builder key, and the thing under test is the
        # policy, not the cryptography -- Task 14 Step 6 covers verification
        # against the real trusted keys on the real box.
        requireSignatures = false;
        # No kiosk in this VM.
        requireKioskUnit = false;
        # The unhealthy case has to actually wait this out.
        watchdogSeconds = 15;
        # The real box's window. The clock is set by hand below.
        activationWindow = {
          start = "03:30";
          end = "05:30";
        };
        # A local stand-in for the nix-cache nginx, for the boot-time fetch.
        cacheUrl = "http://127.0.0.1:8081";
        # requireHealthy is left at its default (true) deliberately -- see
        # the assertion below. The real machine sets this false only because
        # home-player does not exist there yet; this test exists to exercise
        # the watchdog path that setting turns off, so silently inheriting
        # `false` from some future default change would make the "unhealthy
        # backend" subtest pass for no reason at all.
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

      # Fails the build, not just the test, if requireHealthy is ever
      # defaulted or copy-pasted to false in this node -- the whole point of
      # this test is the requireHealthy=true watchdog path.
      assertions = [
        {
          assertion = config.roles.staged-updates.requireHealthy;
          message = "nix/tests/staged-updates.nix: this test exercises the real watchdog path and requires requireHealthy to stay true";
        }
      ];

      # switch-to-configuration is optional in current nixpkgs and this test
      # is entirely about calling it.
      system.switch.enable = true;

      # This VM boots straight from the store via QEMU's -kernel/-initrd,
      # never from the disk's own boot sector, so there is nothing for a
      # real GRUB install to do -- and the test disk's root partition can't
      # take one anyway (grub-install refuses to embed into an ext2
      # filesystem with "blocklists are UNRELIABLE"). Without this,
      # switch-to-configuration's default requireNewInstall path tries a
      # real `grub-install` on the first switch whose grub state differs
      # from the previous one and fails outright. nixpkgs' own
      # nixos/tests/switch-test.nix -- the test this specialisation trick is
      # borrowed from -- disables grub for the identical reason ("Test that
      # no boot loader still switches, e.g. in the ISO").
      boot.loader.grub.enable = false;

      # switch-to-configuration's systemd reload+reactivation dance is slow
      # under the default single vCPU -- observed 70-90s per `switch` call
      # in this VM -- and this subtree calls it four times. More cores
      # shortens that; the timeouts below still assume it can be slow.
      virtualisation.cores = 4;

      # The window is read in the machine's own timezone; the real fleet
      # sets this in base.nix.
      time.timeZone = "Europe/Stockholm";

      # base.nix sets this on the real box; htpc-update-fetch runs `nix copy`.
      nix.settings.experimental-features = [ "nix-command" ];

      systemd.services.fake-cache = {
        description = "Stand-in for the binary cache's pointer directory";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8081 --bind 127.0.0.1 --directory /run/fake-cache";
        };
      };

      systemd.tmpfiles.rules = [
        "d /run/fake-cache/pointers 0755 root root -"
        "d /run/fake-backend 0755 root root -"
        "d /run/fake-ha 0755 root root -"
        # A made-up token; the real one is only ever in 1Password.
        "f+ /run/ha-env 0600 root root - HA_TOKEN=test-ha-token"
        "f /run/fake-backend/busy 0644 root root - false"
        "f /run/fake-backend/healthy 0644 root root - true"
      ];

      systemd.services.fake-home-player = {
        description = "Stand-in for the home-player backend";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${./fake-home-player.py}";
      };

      # The second generation. A specialisation is a full system closure built
      # alongside the parent and reachable at
      # /run/current-system/specialisation/next, so nothing has to be copied
      # into the VM. The kernel and initrd are identical to the parent's, which
      # is what puts this on the `switch` path rather than the `boot` one.
      specialisation.next.configuration = {
        environment.etc."htpc-generation".text = "2";

        # Load-bearing, not decoration. watchdogSeconds is interpolated into
        # htpc-update-watchdog's script (in the requireHealthy branch, which
        # this node is on), htpc-update's script embeds that script's store
        # path to hand to systemd-run, htpc-update-apply's ExecStart embeds
        # htpc-update's, and htpc-update-fetch's script embeds both
        # htpc-update's and htpc-stage's. So changing this one value changes
        # all four services' ExecStart= -- verified by evaluating the role
        # twice with 15 and 16 and diffing the rendered units, and re-asserted
        # from inside the test script below so it cannot rot into a no-op.
        #
        # That is what makes the "idle means it activates" subtest exercise
        # the real hazard: switch-to-configuration-ng puts a unit in its
        # changed-unit diff when the unit is `active` OR `activating`, and a
        # Type=oneshot service is `activating` for the whole of its ExecStart
        # -- so htpc-update.service is in scope for the very switch its own
        # ExecStart is running, and without restartIfChanged = false it would
        # be stopped mid-switch, after the bootloader install and before the
        # activate script.
        #
        # mkForce because the parent already defines watchdogSeconds and a
        # specialisation inherits the parent's config: two equal-priority
        # definitions of one option is an evaluation error, not an override.
        roles.staged-updates.watchdogSeconds = lib.mkForce 16;
      };
    };

  testScript = ''
    import json
    import time

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_open_port(9600)

    base = machine.succeed("readlink -f /run/current-system").strip()
    nxt = machine.succeed("readlink -f /run/current-system/specialisation/next").strip()

    # Guard against a vacuous test. Everything below about restartIfChanged
    # only means anything if the two generations genuinely disagree about
    # these units' definitions -- that is the entire condition under which
    # switch-to-configuration considers a unit "changed" and stops it. If a
    # future edit makes the specialisation differ only in /etc again, this
    # fails here and says so, rather than letting the subtests keep passing
    # while covering nothing.
    for unit in (
        "htpc-update.service",
        "htpc-update-apply.service",
        "htpc-update-fetch.service",
        "htpc-update-watchdog.service",
    ):
        old_def = machine.succeed(f"cat {base}/etc/systemd/system/{unit}")
        new_def = machine.succeed(f"cat {nxt}/etc/systemd/system/{unit}")
        assert old_def != new_def, (
            f"{unit} is identical in both generations, so switching between "
            "them never marks it changed and this test cannot see the "
            "restartIfChanged bug it exists to catch"
        )
        assert "X-RestartIfChanged=false" in new_def, (
            f"{unit} does not carry X-RestartIfChanged=false; "
            "switch-to-configuration would stop it mid-switch"
        )

    # The window is read from the wall clock, so every subtest that expects an
    # activation has to say what time it is. timesyncd, where a node runs it,
    # is stopped so nothing steps the clock back under a subtest (this one
    # does not load it, hence `execute`).
    machine.execute("systemctl stop systemd-timesyncd.service")

    def set_clock(hhmm):
        machine.succeed(f"date -s '2026-11-06 {hhmm}:00'")
        # The unit reads the machine's own zone, so prove the test is in it.
        assert machine.succeed("date +%H:%M").strip() == hhmm, hhmm

    # Inside the window, for everything that predates it.
    set_clock("04:00")

    state_file = "/var/lib/htpc-update/state.json"
    three_nights = 259200

    def read_state():
        return json.loads(machine.succeed(f"cat {state_file}"))

    def patch_state(**fields):
        state = read_state()
        state.update(fields)
        machine.succeed(f"cat > {state_file} <<'EOF'\n{json.dumps(state)}\nEOF")

    def ha_calls():
        out = machine.succeed("cat /run/fake-ha/calls 2>/dev/null || true")
        return [json.loads(line) for line in out.splitlines() if line.strip()]

    def run_alerts():
        # A failed unit is a failure of the test: it must never be one.
        machine.succeed("systemctl start htpc-update-alerts.service")

    def build_finished(seconds_ago):
        now = int(machine.succeed("date +%s"))
        machine.succeed(
            f"echo {now - seconds_ago} > /run/fake-cache/pointers/machine.last-success"
        )

    def no_build_record():
        machine.succeed("rm -f /run/fake-cache/pointers/machine.last-success")

    # A test VM boots straight from a store path, so the system profile has no
    # generations at all -- and with no generation 1 there is nothing to roll
    # back to.
    machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {base}")

    with subtest("busy means nothing happens"):
        machine.succeed("echo true > /run/fake-backend/busy")
        machine.succeed(f"htpc-stage --no-activate {nxt}")
        machine.succeed("systemctl start htpc-update.service")

        assert machine.succeed("readlink -f /run/current-system").strip() == base
        machine.fail("test -e /etc/htpc-generation")

        state = json.loads(machine.succeed("cat /var/lib/htpc-update/state.json"))
        assert state["reason"] == "busy", state
        assert state["pending"] == nxt, state
        assert state["reboot_required"] is False, state
        assert state["age_seconds"] >= 0, state
        # New fields are present, and null where nothing is known: the cache
        # has no last-success record yet, and nothing has been rolled back.
        assert "build_age_seconds" in state and state["build_age_seconds"] is None, state
        assert "rolled_back_at" in state and state["rolled_back_at"] is None, state

    with subtest("idle means it activates"):
        machine.succeed("echo false > /run/fake-backend/busy")
        machine.succeed("systemctl start htpc-update.service")

        # htpc-update's own body performs the switch synchronously -- only
        # the watchdog that verifies the result is detached (systemd-run
        # --collect, not `exec`; see staged-updates.nix's comment on why).
        # So by the time `systemctl start` returns, current-system and
        # /etc/htpc-generation have already flipped.
        # The heart of it. This switch changed htpc-update.service's own
        # ExecStart= (see the specialisation's comment), so without
        # restartIfChanged = false switch-to-configuration would have stopped
        # the cgroup it was running inside: `systemctl start` above would come
        # back non-zero, /run/current-system would still be the OLD generation
        # while /nix/var/nix/profiles/system and the bootloader already point
        # at the new one, and the unit would be left `failed`. All three of
        # those are asserted, because each one is a different half of the same
        # lie: the profile says the update landed, the running system says it
        # did not.
        machine.fail("systemctl is-failed --quiet htpc-update.service")
        assert machine.succeed("readlink -f /run/current-system").strip() == nxt
        assert (
            machine.succeed("readlink -f /nix/var/nix/profiles/system").strip() == nxt
        )
        assert machine.succeed("cat /etc/htpc-generation").strip() == "2"

        # Cleared only by the detached watchdog once it sees the generation
        # healthy, which happens on its own schedule after `systemctl start`
        # has already returned -- poll for the outcome rather than assuming
        # it has landed the instant the command above completes.
        machine.wait_until_succeeds(
            "! test -e /var/lib/htpc-update/verify-after-reboot", timeout=30
        )

    with subtest("an unhealthy backend rolls back and marks the revision bad"):
        # --set, not --rollback: --rollback would leave the nxt generation as
        # the profile's immediate predecessor, so the watchdog's own rollback
        # would land back on the revision under test.
        machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {base}")
        machine.succeed(f"{base}/bin/switch-to-configuration switch")
        machine.succeed(": > /var/lib/htpc-update/bad-revisions")
        machine.wait_for_open_port(9600)

        machine.succeed("echo false > /run/fake-backend/healthy")
        machine.succeed(f"htpc-stage --no-activate {nxt}")

        # `htpc-update` itself is not `exec`'d into the watchdog any more --
        # it does the switch synchronously, then detaches the verification
        # (`systemd-run --collect --unit=htpc-update-watchdog-run-$$
        # <watchdog>`) so that a watchdog running from a config the update
        # itself just replaced can outlive `htpc-update.service`'s own
        # restart. That means `systemctl start` here SUCCEEDS immediately --
        # having already landed on nxt -- and the rollback this subtest
        # cares about happens afterwards, asynchronously, as the detached
        # watchdog polls /health for up to watchdogSeconds. Asserting on the
        # start command's exit code (as a synchronous, `exec`'d watchdog
        # would have allowed) would therefore prove nothing here; the
        # outcome has to be polled for instead.
        machine.succeed("systemctl start htpc-update.service")

        # Confirms htpc-update's own synchronous half landed on nxt, before
        # the detached watchdog has had any chance to roll anything back.
        assert machine.succeed("readlink -f /run/current-system").strip() == nxt

        # watchdogSeconds (15) bounds only the health-poll loop; the actual
        # rollback that follows still has to run a full
        # switch-to-configuration switch, which this VM has observed taking
        # 70-90s on its own under nested virtualisation. 240s leaves a wide
        # margin over that without papering over a genuine hang -- a real
        # hang here means switch-to-configuration itself never returns,
        # which no larger timeout would fix either.
        machine.wait_until_succeeds(
            f'[ "$(readlink -f /run/current-system)" = "{base}" ]', timeout=240
        )

        machine.succeed(f"grep -qxF {nxt} /var/lib/htpc-update/bad-revisions")
        machine.fail("test -L /nix/var/nix/gcroots/htpc-pending")

        # A boot loader may pick the highest generation rather than the
        # profile's current one, as Lanzaboote's `default nixos-*` does, so the
        # bad generation must not still be there, or the next boot returns to it.
        generations = machine.succeed(
            "nix-env -p /nix/var/nix/profiles/system --list-generations"
        ).strip().splitlines()
        assert "(current)" in generations[-1], f"a newer generation remains: {generations}"

        state = json.loads(machine.succeed("cat /var/lib/htpc-update/state.json"))
        assert state["reason"] == "rolled-back", state
        assert state["rolled_back_at"], state

        # RemainAfterExit is what this specific assertion covers: before it,
        # a oneshot unit with no RemainAfterExit goes "inactive" the moment
        # it finishes running, so switch-to-configuration restarts it as
        # wanted-but-inactive on EVERY switch -- not only ones that change
        # this unit's own definition. That is exactly what this subtest's
        # switch does (it changes /etc/htpc-generation, not the role's own
        # config), and it used to start a second, declared instance of this
        # unit racing the transient one htpc-update detaches, both deciding
        # to roll back and both calling `nix-env --rollback` -- the loser
        # died with "Could not acquire lock", was reported as a failed
        # unit, and that made switch-to-configuration -- and therefore
        # htpc-update.service -- fail too. RemainAfterExit alone closes
        # that path (the unit stays "active (exited)" so it is never
        # "wanted but inactive" for an unrelated switch to restart).
        #
        # This subtest's switches DO now change htpc-update-watchdog.service's
        # own definition as well (the specialisation moves watchdogSeconds),
        # so this assertion covers the restartIfChanged path too and not only
        # the RemainAfterExit one it was originally written for. The earlier
        # version of this comment said the opposite, correctly at the time:
        # the specialisation then differed only in /etc/htpc-generation.
        machine.fail("systemctl is-failed --quiet htpc-update-watchdog.service")

    with subtest("a rollback is reported once"):
        assert ha_calls() == [], ha_calls()
        run_alerts()
        calls = ha_calls()
        assert len(calls) == 1, calls
        assert calls[0]["service"] == "mobile_app_pixel_8", calls
        # The token was sent, as a bearer token, and is not in any unit.
        assert calls[0]["auth_ok"] is True, calls
        assert "rolled back" in calls[0]["message"], calls
        machine.fail("grep -r test-ha-token /etc/systemd/system")

        run_alerts()
        assert len(ha_calls()) == 1, ha_calls()

    with subtest("a bad revision already reported is not reported again"):
        other = "/nix/store/00000000000000000000000000000000-other-bad"
        machine.succeed(f"echo {other} >> /var/lib/htpc-update/bad-revisions")
        run_alerts()
        calls = ha_calls()
        assert len(calls) == 2, calls
        assert other in calls[1]["message"], calls
        assert nxt not in calls[1]["message"], calls
        run_alerts()
        assert len(ha_calls()) == 2, ha_calls()

    with subtest("three nights without a build alerts once per stale period"):
        build_finished(three_nights + 60)
        run_alerts()
        calls = ha_calls()
        assert len(calls) == 3, calls
        assert "3 nights" in calls[2]["message"], calls
        run_alerts()
        assert len(ha_calls()) == 3, ha_calls()

        # A build comes in; the period is over, and the next one is news again.
        build_finished(60)
        run_alerts()
        assert len(ha_calls()) == 3, ha_calls()
        build_finished(three_nights + 60)
        run_alerts()
        assert len(ha_calls()) == 4, ha_calls()

        # Just under three nights is not stale.
        build_finished(three_nights - 3600)
        run_alerts()
        no_build_record()
        run_alerts()
        assert len(ha_calls()) == 4, ha_calls()

    with subtest("an update waiting three nights alerts once per stale period"):
        now = int(machine.succeed("date +%s"))
        patch_state(staged_at=now - three_nights - 60)
        run_alerts()
        calls = ha_calls()
        assert len(calls) == 5, calls
        assert "3 nights" in calls[4]["message"], calls
        run_alerts()
        assert len(ha_calls()) == 5, ha_calls()
        patch_state(staged_at=0)
        run_alerts()
        patch_state(staged_at=now - three_nights - 60)
        run_alerts()
        assert len(ha_calls()) == 6, ha_calls()
        patch_state(staged_at=0)
        run_alerts()

    with subtest("the alert check never writes state.json"):
        # The updater and its watchdog own that file; a second writer can put an
        # older state back over theirs. Sentinels the check would overwrite.
        patch_state(staged_at=0, age_seconds=888, build_age_seconds=777)
        before = machine.succeed(f"cat {state_file}")
        build_finished(100)
        run_alerts()
        no_build_record()
        run_alerts()
        assert machine.succeed(f"cat {state_file}") == before

    seen_file = "/var/lib/htpc-update/alerts-build-seen"

    def set_unheard_for(seconds):
        now = int(machine.succeed("date +%s"))
        machine.succeed(f"echo {now - seconds} > {seen_file}")

    with subtest("a cache that cannot be reached for three nights alerts once"):
        # Nothing is staged then either, so age_seconds is 0 and the build age
        # unknown: the likeliest way for updates to stop is otherwise silent.
        no_build_record()
        before = len(ha_calls())
        set_unheard_for(three_nights - 3600)
        run_alerts()
        assert len(ha_calls()) == before, ha_calls()

        set_unheard_for(three_nights + 60)
        run_alerts()
        calls = ha_calls()
        assert len(calls) == before + 1, calls
        assert "update cache" in calls[-1]["message"], calls
        run_alerts()
        assert len(ha_calls()) == before + 1, ha_calls()

        # The cache answers once: that period is over and counting restarts, so
        # it going quiet again is not the same period and not yet three nights.
        build_finished(60)
        run_alerts()
        no_build_record()
        run_alerts()
        assert len(ha_calls()) == before + 1, ha_calls()

    with subtest("a cache that comes and goes inside a period does not re-send"):
        before = len(ha_calls())
        build_finished(three_nights + 60)
        run_alerts()
        assert len(ha_calls()) == before + 1, ha_calls()
        # A night with no answer proves nothing, so it does not end the period.
        no_build_record()
        run_alerts()
        build_finished(three_nights + 60)
        run_alerts()
        assert len(ha_calls()) == before + 1, ha_calls()
        build_finished(60)
        run_alerts()

    with subtest("a box that has never heard from the cache starts counting then"):
        machine.succeed(f"rm -f {seen_file}")
        no_build_record()
        before = len(ha_calls())
        run_alerts()
        assert len(ha_calls()) == before, ha_calls()
        machine.succeed(f"test -s {seen_file}")
        set_unheard_for(three_nights + 60)
        run_alerts()
        assert len(ha_calls()) == before + 1, ha_calls()
        build_finished(60)
        run_alerts()

    with subtest("garbage and future last-success content is not a build time"):
        now = int(machine.succeed("date +%s"))
        before = len(ha_calls())
        set_unheard_for(60)
        stamp = machine.succeed(f"cat {seen_file}")
        machine.succeed("echo 'not a number' > /run/fake-cache/pointers/machine.last-success")
        run_alerts()
        assert machine.succeed(f"cat {seen_file}") == stamp, "garbage counted as a reply"
        # A build from the future is a clock disagreement, and it is a number.
        machine.succeed(f"echo {now + 10 * 86400} > /run/fake-cache/pointers/machine.last-success")
        run_alerts()
        assert machine.succeed(f"cat {seen_file}") != stamp, "a future time was not read as a number"
        assert len(ha_calls()) == before, ha_calls()
        no_build_record()

    with subtest("an unreadable state.json does not stop the other checks"):
        good = machine.succeed(f"cat {state_file}")
        build_finished(three_nights + 60)
        run_alerts()
        flag = "/var/lib/htpc-update/alerts-stale-build"
        machine.succeed(f"test -e {flag}")
        before = len(ha_calls())

        late = "/nix/store/22222222222222222222222222222222-late-bad"
        machine.succeed(f"echo {late} >> /var/lib/htpc-update/bad-revisions")
        for broken in ("{nope", "[1]", ""):
            machine.succeed(f"printf '%s' '{broken}' > {state_file}")
            if broken == "{nope":
                run_alerts()
                calls = ha_calls()
                assert len(calls) == before + 1 and late in calls[-1]["message"], calls
            else:
                run_alerts()
            assert machine.succeed(f"cat {state_file}") == broken
            # Still the same period: nothing cleared it, nothing re-sent.
            machine.succeed(f"test -e {flag}")
            assert len(ha_calls()) == before + 1, ha_calls()
        machine.succeed(f"rm -f {state_file}")
        run_alerts()
        machine.succeed(f"test -e {flag}")
        assert len(ha_calls()) == before + 1, ha_calls()
        machine.succeed(f"cat > {state_file} <<'EOF'\n{good}\nEOF")
        build_finished(60)
        run_alerts()
        machine.fail(f"test -e {flag}")
        no_build_record()

    with subtest("an unreachable Home Assistant changes nothing it reports on"):
        sixth = "/nix/store/11111111111111111111111111111111-unreachable-bad"
        machine.succeed(f"echo {sixth} >> /var/lib/htpc-update/bad-revisions")
        told = len(ha_calls())
        before_system = machine.succeed("readlink -f /run/current-system")
        before_reason = read_state()["reason"]

        machine.succeed("systemctl stop fake-ha.service")
        run_alerts()
        machine.fail("systemctl is-failed --quiet htpc-update-alerts.service")
        assert machine.succeed("readlink -f /run/current-system") == before_system
        assert read_state()["reason"] == before_reason
        machine.succeed("journalctl -u htpc-update-alerts.service | grep -q 'not delivered'")

        # The notifier itself, not only the unit around it, promises to exit 0.
        machine.succeed(
            "set -a; . /run/ha-env; HA_URL=http://127.0.0.1:8123 "
            "HA_NOTIFY_SERVICE=notify.mobile_app_pixel_8 ha-notify title message"
        )
        machine.succeed("HA_URL=http://127.0.0.1:8123 ha-notify title message")

        # Reachable but unwilling is the same.
        machine.succeed("systemctl start fake-ha.service")
        machine.wait_for_open_port(8123)
        machine.succeed("touch /run/fake-ha/refuse")
        run_alerts()
        assert len(ha_calls()) == told, ha_calls()

        # Not remembered as told, so it is told when Home Assistant is back.
        machine.succeed("rm /run/fake-ha/refuse")
        run_alerts()
        calls = ha_calls()
        assert len(calls) == told + 1 and sixth in calls[-1]["message"], calls
        run_alerts()
        assert len(ha_calls()) == told + 1, ha_calls()

    with subtest("a known-bad revision is not retried"):
        machine.succeed("echo true > /run/fake-backend/healthy")
        # Refused at the door, so the fifteen-minute timer cannot loop on it.
        machine.fail(f"htpc-stage --no-activate {nxt}")

        # htpc-stage's refusal above never re-links the gcroot -- and the
        # previous subtest's watchdog already removed it before rolling
        # back -- so without this, htpc-update would take the `[ ! -L
        # pendingRoot ]` -> write_state none -> exit branch instead of the
        # bad-revisions branch this subtest is named for, and that branch
        # would have no coverage anywhere in the suite. Re-link it directly
        # to simulate a gcroot that survives from before the revision was
        # marked bad (e.g. one written on a prior boot), so htpc-update's
        # own bad-revisions check -- not just htpc-stage's door check
        # above -- actually runs.
        machine.succeed(f"ln -sfn {nxt} /nix/var/nix/gcroots/htpc-pending")

        machine.succeed("systemctl start htpc-update.service")
        assert machine.succeed("readlink -f /run/current-system").strip() == base

        state = json.loads(machine.succeed("cat /var/lib/htpc-update/state.json"))
        assert state["reason"] == "bad", state
        # Every later outcome keeps the record of the rollback.
        assert state["rolled_back_at"], state

    # Everything below drives the watchdog directly, with a marker it believes
    # is its own, because both failures need the profile in a state no ordinary
    # update leaves it in.
    profile = "/nix/var/nix/profiles/system"

    def generations():
        return machine.succeed(f"nix-env -p {profile} --list-generations")

    def watchdog_verifies(pending):
        machine.succeed("echo false > /run/fake-backend/healthy")
        machine.succeed(": > /var/lib/htpc-update/bad-revisions")
        machine.succeed(f"echo {pending} > /var/lib/htpc-update/verify-after-reboot")
        # restart, not start: the unit has RemainAfterExit, so `start` on one
        # still "active" from an earlier run would do nothing.
        # The timeout turns the old hang into a failure: a rollback that reaches
        # `switch` from this declared unit waits on itself.
        status, _ = machine.execute(
            "systemctl restart htpc-update-watchdog.service", timeout=90
        )
        assert status != 0, "the watchdog reported success on a failed rollback"

    def assert_rollback_failed_stays(pending):
        machine.succeed(f"grep -qxF {pending} /var/lib/htpc-update/bad-revisions")
        state = json.loads(machine.succeed("cat /var/lib/htpc-update/state.json"))
        assert state["reason"] == "rollback-failed", state

        machine.succeed("systemctl start htpc-update.service")
        state = json.loads(machine.succeed("cat /var/lib/htpc-update/state.json"))
        assert state["reason"] == "rollback-failed", state

    with subtest("a stale marker moves and deletes nothing"):
        # Someone rolled back by hand after the marker was written: the profile
        # is on base, with the marker's generation above it. Rolling back from
        # here would land below base and delete a good generation.
        machine.succeed(f"nix-env -p {profile} --set {base}")
        good = generations().strip().splitlines()[-1].split()[0]
        machine.succeed(f"nix-env -p {profile} --set {nxt}")
        machine.succeed(f"nix-env -p {profile} --switch-generation {good}")
        before = generations()

        watchdog_verifies(nxt)

        assert generations() == before, f"generations changed: {generations()}"
        assert machine.succeed(f"readlink -f {profile}").strip() == base
        assert machine.succeed("readlink -f /run/current-system").strip() == base
        assert_rollback_failed_stays(nxt)

    with subtest("a bad generation that cannot be deleted stops the rollback"):
        # On nxt, so a rollback going on regardless would show: `switch` would
        # land on base. This VM's two generations share a kernel, so the reboot
        # path is not reachable here. The boot ID covers it anyway, and the
        # guard sits ahead of both paths.
        machine.succeed(f"nix-env -p {profile} --set {nxt}")
        machine.succeed(f"{nxt}/bin/switch-to-configuration switch")
        boot_id = machine.succeed("cat /proc/sys/kernel/random/boot_id")

        # Nix removes a generation with remove(), which refuses a non-empty
        # directory, so --rollback works and the deletion after it fails.
        machine.succeed(f"mkdir -p {profile}-9999-link/keep && touch {profile}-9999-link/keep/file")

        watchdog_verifies(nxt)

        assert machine.succeed("readlink -f /run/current-system").strip() == nxt
        assert machine.succeed("cat /proc/sys/kernel/random/boot_id") == boot_id
        assert_rollback_failed_stays(nxt)
        machine.succeed(f"rm -rf {profile}-9999-link")

    with subtest("a failed rollback is reported"):
        before = len(ha_calls())
        run_alerts()
        calls = ha_calls()
        assert len(calls) == before + 1, calls
        assert "could not be rolled back" in calls[-1]["message"], calls
        run_alerts()
        assert len(ha_calls()) == before + 1, ha_calls()

    # ---- the activation window --------------------------------------------
    # Unattended activation only happens at night. The earlier subtests leave
    # the box on nxt with a failed rollback recorded, so each of these starts by
    # putting it back on base. state.json is kept across that on purpose: the
    # first subtest needs the leftover rollback-failed.
    def back_to_base(keep_state=True):
        machine.succeed(f"nix-env -p {profile} --set {base}")
        machine.succeed(f"{base}/bin/switch-to-configuration switch")
        machine.succeed("echo false > /run/fake-backend/busy")
        machine.succeed("echo true > /run/fake-backend/healthy")
        machine.succeed(": > /var/lib/htpc-update/bad-revisions")
        machine.succeed("rm -f /var/lib/htpc-update/verify-after-reboot")
        if not keep_state:
            machine.succeed("rm -f /var/lib/htpc-update/state.json")
        machine.wait_for_open_port(9600)

    def reason():
        return json.loads(machine.succeed("cat /var/lib/htpc-update/state.json"))["reason"]

    def stage_and_run_at(hhmm):
        set_clock(hhmm)
        machine.succeed(f"htpc-stage --no-activate {nxt}")
        # Several starts in a few seconds trip systemd's start-rate limit,
        # which is nothing to do with what is under test.
        machine.succeed("systemctl reset-failed htpc-update.service")
        machine.succeed("systemctl start htpc-update.service")

    with subtest("outside the window nothing activates, even when idle"):
        back_to_base()
        assert reason() == "rollback-failed", reason()

        # A failed rollback waits for a person; the window must not bury it.
        stage_and_run_at("12:00")
        assert machine.succeed("readlink -f /run/current-system").strip() == base
        assert reason() == "rollback-failed", reason()

        machine.succeed("rm -f /var/lib/htpc-update/state.json")
        # Idle, healthy, and staged -- the only thing wrong is the hour. The
        # edges are half-open: 03:30 is in, 05:30 is out.
        for hhmm in ("12:00", "03:29", "05:30", "23:59"):
            stage_and_run_at(hhmm)
            assert machine.succeed("readlink -f /run/current-system").strip() == base, hhmm
            state = json.loads(machine.succeed("cat /var/lib/htpc-update/state.json"))
            assert state["reason"] == "outside-window", (hhmm, state)
            assert state["pending"] == nxt, state
            assert state["reboot_required"] is False, state
            machine.fail("test -e /etc/htpc-generation")

    with subtest("inside the window an idle box activates"):
        stage_and_run_at("03:30")
        assert machine.succeed("readlink -f /run/current-system").strip() == nxt
        assert machine.succeed("cat /etc/htpc-generation").strip() == "2"
        machine.wait_until_succeeds(
            "! test -e /var/lib/htpc-update/verify-after-reboot", timeout=60
        )

    with subtest("a good later update clears rolled_back_at"):
        back_to_base()
        build_finished(100)
        patch_state(rolled_back_at="2026-11-05T01:00:00Z")

        # Every other outcome keeps it, or the notice would go with the next
        # run that has nothing to do.
        stage_and_run_at("12:00")
        assert reason() == "outside-window", reason()
        assert read_state()["rolled_back_at"] == "2026-11-05T01:00:00Z", read_state()

        # Only a proved-healthy update takes it away. The watchdog clears its
        # marker a moment before it writes the state, so wait for the state.
        stage_and_run_at("03:30")
        for _ in range(60):
            state = read_state()
            if state["reason"] == "none" and state["rolled_back_at"] is None:
                break
            time.sleep(1)
        else:
            raise AssertionError(f"rolled_back_at was not cleared: {state}")
        # And with a record of the last build, the age is a number.
        age = read_state()["build_age_seconds"]
        assert 90 <= age < 600, age
        no_build_record()

    with subtest("--force-idle ignores the window"):
        back_to_base(keep_state=False)
        set_clock("12:00")
        machine.succeed(f"htpc-stage --no-activate {nxt}")
        machine.succeed("systemctl start htpc-update.service")
        assert machine.succeed("readlink -f /run/current-system").strip() == base

        # htpc-update-apply is htpc-update --force-idle.
        machine.succeed("systemctl start htpc-update-apply.service")
        assert machine.succeed("readlink -f /run/current-system").strip() == nxt
        machine.wait_until_succeeds(
            "! test -e /var/lib/htpc-update/verify-after-reboot", timeout=60
        )

    with subtest("htpc-stage --now is the urgent path"):
        back_to_base(keep_state=False)
        set_clock("12:00")
        machine.succeed(f"htpc-stage --now {nxt}")
        machine.wait_until_succeeds(
            f'[ "$(readlink -f /run/current-system)" = "{nxt}" ]', timeout=240
        )
        machine.wait_until_succeeds(
            "! test -e /var/lib/htpc-update/verify-after-reboot", timeout=60
        )

    with subtest("boot-time fetch stages but honours the window"):
        back_to_base(keep_state=False)
        machine.succeed("rm -f /nix/var/nix/gcroots/htpc-pending")
        set_clock("12:00")
        # The specialisation cannot stand in: this VM's store database does not
        # register its closure, so it cannot be put in a cache. A fresh,
        # reference-free path can.
        machine.succeed("mkdir -p /tmp/nixos-system-fetched && echo fetched > /tmp/nixos-system-fetched/marker")
        fetched = machine.succeed("nix-store --add /tmp/nixos-system-fetched").strip()
        machine.succeed(f"nix copy --to file:///run/fake-cache {fetched}")
        machine.succeed(f"echo {fetched} > /run/fake-cache/pointers/machine")
        machine.wait_for_unit("fake-cache.service")
        machine.succeed("systemctl start htpc-update-fetch.service")

        assert machine.succeed("readlink -f /nix/var/nix/gcroots/htpc-pending").strip() == fetched
        assert machine.succeed("readlink -f /run/current-system").strip() == base
        assert reason() == "outside-window", reason()
  '';
}
