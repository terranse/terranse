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
    { pkgs, lib, config, ... }:
    {
      imports = [ ../roles/staged-updates.nix ];

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
        # requireHealthy is left at its default (true) deliberately -- see
        # the assertion below. The real machine sets this false only because
        # home-player does not exist there yet; this test exists to exercise
        # the watchdog path that setting turns off, so silently inheriting
        # `false` from some future default change would make the "unhealthy
        # backend" subtest pass for no reason at all.
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

      systemd.tmpfiles.rules = [
        "d /run/fake-backend 0755 root root -"
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

        state = json.loads(machine.succeed("cat /var/lib/htpc-update/state.json"))
        assert state["reason"] == "rolled-back", state

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
  '';
}
