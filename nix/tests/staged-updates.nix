# Boot a VM, stage a second generation, and assert the three things the policy
# exists to get right: busy means nothing happens, idle means it activates,
# and an unhealthy backend means it rolls back *and* marks the revision bad so
# the timer does not retry it every fifteen minutes.
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
      };
    };

  testScript = ''
    import json

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_open_port(9600)

    base = machine.succeed("readlink -f /run/current-system").strip()
    nxt = machine.succeed("readlink -f /run/current-system/specialisation/next").strip()

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
        assert machine.succeed("readlink -f /run/current-system").strip() == nxt
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
        # This assertion does NOT exercise the separate, more dangerous
        # path restartIfChanged/stopIfChanged (also in staged-updates.nix)
        # closes -- a switch that changes htpc-update-watchdog.service's
        # OWN definition, which this test's specialisation never does (it
        # only touches /etc/htpc-generation). Proving that path would need
        # a specialisation that edits roles.staged-updates itself; not
        # added here since it would not exercise anything about the
        # activation *policy*, which is what this whole test is for.
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
