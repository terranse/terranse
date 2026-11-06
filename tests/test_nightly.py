"""scripts/nightly.sh against stub nix, ship.sh and ha-notify.sh, and a real
throwaway git repo with a bare remote. Nothing real is touched."""

import os
import subprocess
import time
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "nightly.sh"
NIGHT = 86400

NIX_STUB = r"""#!/usr/bin/env bash
echo "nix $*" >> "$STUB_LOG"
case "$1" in
  eval) printf '%s' "$STUB_CHECKS" ;;
  flake)
    if [ -n "${STUB_NO_CHANGE:-}" ]; then exit 0; fi
    if [ "${3:-}" = "home-player" ]; then
      echo hp >> flake.lock
      echo "• Updated input 'home-player':" >&2
    else
      echo all >> flake.lock
      echo "• Updated input 'nixpkgs':" >&2
      echo "• Updated input 'home-player':" >&2
    fi ;;
  build)
    [ -z "${STUB_FAIL_ALL:-}" ] || ! grep -qx all flake.lock || exit 1
    [ -z "${STUB_FAIL_HP:-}" ] || ! grep -qx hp flake.lock || exit 1
    [ -z "${STUB_FAIL_BUILD:-}" ] || case "$*" in *"$STUB_FAIL_BUILD"*) exit 1 ;; esac ;;
esac
"""
SHIP_STUB = """#!/usr/bin/env bash
echo "ship $*" >> "$STUB_LOG"
exit "${STUB_SHIP_RC:-0}"
"""
NOTIFY_STUB = """#!/usr/bin/env bash
echo "notify $*" >> "$STUB_LOG"
[ -z "${STUB_NOTIFY_FAIL:-}" ] || : > "$HA_NOTIFY_FAILED_FLAG"
"""
DF_STUB = """#!/usr/bin/env bash
echo "df $*" >> "$STUB_LOG"
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/root 209715200 0 0 ${STUB_DISK_PCT:-10}% /"
"""


def sh(*cmd, cwd, **kw):
    return subprocess.run(cmd, cwd=cwd, check=True, capture_output=True, text=True, **kw)


@pytest.fixture
def env(tmp_path):
    bare = tmp_path / "bare.git"
    sh("git", "init", "--bare", "-b", "main", str(bare), cwd=tmp_path)
    work = tmp_path / "work"
    sh("git", "clone", str(bare), str(work), cwd=tmp_path)
    for k, v in (("user.name", "t"), ("user.email", "t@t")):
        sh("git", "config", k, v, cwd=work)
    (work / "flake.lock").write_text("base\n")
    sh("git", "add", "flake.lock", cwd=work)
    sh("git", "commit", "-m", "init", cwd=work)
    sh("git", "push", "origin", "HEAD:main", cwd=work)

    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for name, body in (("nix", NIX_STUB), ("ship", SHIP_STUB), ("notify", NOTIFY_STUB), ("df", DF_STUB)):
        f = bin_dir / name
        f.write_text(body)
        f.chmod(0o755)
    cache = tmp_path / "cache"
    (cache / "pointers").mkdir(parents=True)
    kvm = tmp_path / "kvm"
    kvm.write_text("")
    log = tmp_path / "calls.log"
    log.write_text("")
    e = {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "STUB_LOG": str(log),
        "STUB_CHECKS": "reg plain\nvmtest vm\nmachine-htpc plain",
        "NIX_CACHE_DIR": str(cache),
        "NIGHTLY_STATE_DIR": str(tmp_path / "state"),
        "NIGHTLY_SHIP": str(bin_dir / "ship"),
        "NIGHTLY_NOTIFY": str(bin_dir / "notify"),
        "NIGHTLY_KVM": str(kvm),
        "NIGHTLY_REMOTE": "origin",
        "NIGHTLY_BRANCH": "main",
        "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
        "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
    }

    class E:
        pass

    o = E()
    o.work, o.bare, o.env, o.cache, o.log, o.kvm = work, bare, e, cache, log, kvm
    o.last = cache / "pointers" / "htpc.last-success"

    def run(**extra):
        return subprocess.run(
            [str(SCRIPT), "htpc"], cwd=work, env={**e, **extra},
            capture_output=True, text=True,
        )

    o.run = run
    o.calls = lambda: log.read_text().splitlines()
    o.head = lambda: sh("git", "rev-parse", "HEAD", cwd=work).stdout.strip()
    o.remote_head = lambda: sh("git", "rev-parse", "main", cwd=bare).stdout.strip()
    o.published = lambda: sh("git", "rev-parse", "nightly/htpc", cwd=bare).stdout.strip()
    o.set_age = lambda nights: o.last.write_text(f"{int(time.time()) - nights * NIGHT}\n")
    return o


def test_all_inputs_pass_ships_and_commits(env):
    before = env.head()
    r = env.run()
    assert r.returncode == 0, r.stderr
    assert env.head() != before
    msg = sh("git", "log", "-1", "--format=%B", cwd=env.work).stdout
    assert msg.startswith("chore(nix): nightly bump [skip ci]")
    assert "nixpkgs" in msg and "home-player" in msg
    # Published on its own branch; the branch people push to is not touched.
    assert env.remote_head() == before
    assert env.published() == env.head()
    assert sh("git", "rev-parse", "nightly/htpc~1", cwd=env.bare).stdout.strip() == before
    ships = [c for c in env.calls() if c.startswith("ship")]
    assert ships == ["ship htpc --no-push"]
    assert int(env.last.read_text().strip()) >= int(time.time()) - 60
    assert not list((env.cache / "pointers").glob("*.new"))


def test_failed_all_bump_retries_home_player_only(env):
    r = env.run(STUB_FAIL_ALL="1")
    assert r.returncode == 0, r.stderr
    calls = env.calls()
    updates = [c for c in calls if c.startswith("nix flake update")]
    assert updates == ["nix flake update", "nix flake update home-player"]
    lock = (env.work / "flake.lock").read_text().split()
    assert lock == ["base", "hp"]  # the failed bump's change was restored first
    msg = sh("git", "log", "-1", "--format=%B", cwd=env.work).stdout
    assert "home-player" in msg and "nixpkgs" not in msg
    assert [c for c in calls if c.startswith("ship")] == ["ship htpc --no-push"]
    assert env.last.exists()


def test_both_fail_publishes_nothing(env):
    env.last.write_text("12345\n")
    before = env.head()
    r = env.run(STUB_FAIL_ALL="1", STUB_FAIL_HP="1")
    assert r.returncode != 0
    assert not [c for c in env.calls() if c.startswith("ship")]
    assert env.last.read_text() == "12345\n"
    assert env.head() == before and env.remote_head() == before
    assert (env.work / "flake.lock").read_text() == "base\n"


def test_alerts_only_after_three_nights(env):
    env.set_age(2)
    env.run(STUB_FAIL_ALL="1", STUB_FAIL_HP="1")
    assert not [c for c in env.calls() if c.startswith("notify")]
    env.set_age(3)
    env.run(STUB_FAIL_ALL="1", STUB_FAIL_HP="1")
    assert len([c for c in env.calls() if c.startswith("notify")]) == 1
    # Still stale the next night: the same stale period alerts once.
    env.run(STUB_FAIL_ALL="1", STUB_FAIL_HP="1")
    assert len([c for c in env.calls() if c.startswith("notify")]) == 1


def test_alert_again_after_recovery_and_new_staleness(env):
    env.set_age(3)
    env.run(STUB_FAIL_ALL="1", STUB_FAIL_HP="1")
    assert env.run().returncode == 0  # recovers, new last-success
    env.set_age(4)  # a later, different stale period
    env.run(STUB_FAIL_ALL="1", STUB_FAIL_HP="1")
    assert len([c for c in env.calls() if c.startswith("notify")]) == 2


def test_no_alert_on_success(env):
    env.set_age(5)
    assert env.run().returncode == 0
    assert not [c for c in env.calls() if c.startswith("notify")]


def test_ship_failure_does_not_record_success(env):
    env.last.write_text("12345\n")
    r = env.run(STUB_SHIP_RC="1")
    assert r.returncode != 0
    assert env.last.read_text() == "12345\n"


def test_build_failure_after_bump_never_commits(env):
    before = env.head()
    r = env.run(STUB_FAIL_BUILD="machine-htpc")
    assert r.returncode != 0
    assert env.head() == before
    assert env.remote_head() == before
    assert not [c for c in env.calls() if c.startswith("ship")]


def test_no_changes_still_records_success(env):
    before = env.head()
    r = env.run(STUB_NO_CHANGE="1")
    assert r.returncode == 0, r.stderr
    assert env.head() == before
    assert env.last.exists()
    assert [c for c in env.calls() if c.startswith("ship")] == ["ship htpc --no-push"]


def test_dirty_checkout_refuses(env):
    (env.work / "flake.lock").write_text("local edit\n")
    r = env.run()
    assert r.returncode != 0
    assert not [c for c in env.calls() if c.startswith("nix flake update")]
    assert (env.work / "flake.lock").read_text() == "local edit\n"
    assert "dirty" in r.stderr


def test_no_kvm_skips_only_vm_tests_loudly(env):
    r = env.run(NIGHTLY_KVM=str(env.kvm) + ".missing")
    assert r.returncode == 0, r.stderr
    builds = [c for c in env.calls() if c.startswith("nix build")]
    assert any(".#checks.x86_64-linux.reg" in b for b in builds)
    assert any(".#checks.x86_64-linux.machine-htpc" in b for b in builds)
    assert not any("vmtest" in b for b in builds)
    assert "SKIPPING VM test vmtest" in r.stderr


def test_kvm_builds_vm_tests(env):
    env.run()
    assert any("checks.x86_64-linux.vmtest" in c for c in env.calls() if c.startswith("nix build"))


def test_empty_check_list_fails(env):
    r = env.run(STUB_CHECKS="")
    assert r.returncode != 0
    assert not [c for c in env.calls() if c.startswith("ship")]


def write_baseline(env, nights):
    state = Path(env.env["NIGHTLY_STATE_DIR"])
    state.mkdir(parents=True, exist_ok=True)
    (state / "htpc.first-failure").write_text(f"{int(time.time()) - nights * NIGHT}\n")


BAD = dict(STUB_FAIL_ALL="1", STUB_FAIL_HP="1")


def notifies(env):
    return [c for c in env.calls() if c.startswith("notify")]


def test_never_succeeded_old_baseline_alerts_once(env):
    write_baseline(env, 4)
    env.run(**BAD)
    env.run(**BAD)
    assert len(notifies(env)) == 1


def test_never_succeeded_fresh_baseline_is_silent(env):
    write_baseline(env, 1)
    env.run(**BAD)
    assert not notifies(env)


def test_first_failure_seeds_baseline(env):
    env.run(**BAD)
    state = Path(env.env["NIGHTLY_STATE_DIR"])
    assert int((state / "htpc.first-failure").read_text()) >= int(time.time()) - 60
    assert not notifies(env)


def test_unparseable_last_success_uses_baseline(env):
    env.last.write_text("garbage\n")
    write_baseline(env, 4)
    env.run(**BAD)
    assert len(notifies(env)) == 1


def test_success_clears_baseline(env):
    write_baseline(env, 4)
    assert env.run().returncode == 0
    assert not (Path(env.env["NIGHTLY_STATE_DIR"]) / "htpc.first-failure").exists()


def test_failed_delivery_retries_next_night(env):
    env.set_age(3)
    env.run(STUB_NOTIFY_FAIL="1", **BAD)
    env.run(STUB_NOTIFY_FAIL="1", **BAD)
    assert len(notifies(env)) == 2  # not stamped, so tried again
    env.run(**BAD)  # delivered this time
    env.run(**BAD)
    assert len(notifies(env)) == 3  # and now stamped


def laptop_pushes(env, text, force=False):
    """Someone pushes to the tracked branch from elsewhere, as the laptop does."""
    other = env.work.parent / "laptop"
    if not other.exists():
        sh("git", "clone", str(env.bare), str(other), cwd=env.work.parent)
    sh("git", "fetch", "origin", cwd=other)
    sh("git", "checkout", "-B", "main", "origin/main", cwd=other)
    if force:
        sh("git", "reset", "--hard", "HEAD~0", cwd=other)
        (other / "flake.lock").write_text(text)
        sh("git", "-c", "user.name=l", "-c", "user.email=l@l", "commit", "--amend", "-qam", "rewritten", cwd=other)
        sh("git", "push", "-f", "origin", "HEAD:main", cwd=other)
    else:
        (other / "notes").write_text(text)
        sh("git", "add", "notes", cwd=other)
        sh("git", "-c", "user.name=l", "-c", "user.email=l@l", "commit", "-qm", text, cwd=other)
        sh("git", "push", "origin", "HEAD:main", cwd=other)
    return sh("git", "rev-parse", "HEAD", cwd=other).stdout.strip()


def test_each_night_starts_from_the_tracked_branch(env):
    assert env.run().returncode == 0
    first = env.published()
    tip = laptop_pushes(env, "laptop work")
    r = env.run()
    assert r.returncode == 0, r.stderr
    # Built on what was pushed, not on last night's bump.
    assert sh("git", "rev-parse", "nightly/htpc~1", cwd=env.bare).stdout.strip() == tip
    assert env.published() != first
    assert env.remote_head() == tip


def test_a_force_pushed_tracked_branch_does_not_break_the_night(env):
    assert env.run().returncode == 0
    tip = laptop_pushes(env, "rewritten\n", force=True)
    r = env.run()
    assert r.returncode == 0, r.stderr
    assert sh("git", "rev-parse", "nightly/htpc~1", cwd=env.bare).stdout.strip() == tip
    assert env.remote_head() == tip


def test_nothing_to_bump_publishes_the_tracked_branch(env):
    # The published branch always names what the pointer was built from.
    r = env.run(STUB_NO_CHANGE="1")
    assert r.returncode == 0, r.stderr
    assert env.published() == env.remote_head()


def test_failed_night_publishes_no_branch(env):
    env.run(STUB_FAIL_BUILD="machine-htpc")
    r = subprocess.run(["git", "rev-parse", "--verify", "-q", "nightly/htpc"],
                       cwd=env.bare, capture_output=True, text=True)
    assert r.returncode != 0


def disk_notifies(env):
    return [c for c in notifies(env) if "disk" in c.lower()]


def test_disk_over_80_percent_alerts_once_per_period(env):
    assert env.run(STUB_DISK_PCT="81").returncode == 0
    assert len(disk_notifies(env)) == 1
    env.run(STUB_DISK_PCT="90")
    assert len(disk_notifies(env)) == 1
    # Back under: the period is over, and the next one is news again.
    env.run(STUB_DISK_PCT="60")
    env.run(STUB_DISK_PCT="85")
    assert len(disk_notifies(env)) == 2


def test_disk_at_80_percent_is_fine(env):
    env.run(STUB_DISK_PCT="80")
    assert not disk_notifies(env)


def test_disk_alert_also_on_a_failed_night(env):
    r = env.run(STUB_DISK_PCT="95", **BAD)
    assert r.returncode != 0
    assert len(disk_notifies(env)) == 1


def test_disk_alert_not_delivered_is_tried_again(env):
    env.run(STUB_DISK_PCT="95", STUB_NOTIFY_FAIL="1")
    env.run(STUB_DISK_PCT="95")
    env.run(STUB_DISK_PCT="95")
    assert len(disk_notifies(env)) == 2


def test_disk_check_reads_the_root_filesystem(env):
    env.run()
    assert [c for c in env.calls() if c.startswith("df")] == ["df -P /"]
