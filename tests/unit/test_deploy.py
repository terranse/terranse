"""scripts/deploy.sh (`just deploy`) against a real throwaway git repo, a bare
remote standing in for nixhost's, and stub ssh, systemctl, journalctl, curl and
ship.sh. Nothing real is touched."""

import json
import os
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "deploy.sh"
POINTER = "/nix/store/cccccccccccccccccccccccccccccccc-nixos-system-htpc"

STUBS = {
    # nixhost's commands run here, against the stubs below; the box is never
    # reached by ssh, because ship.sh is a stub too.
    "ssh": r"""
echo "ssh $*" >> "$STUB_LOG"
while [ "${1:-}" = -o ]; do shift 2; done
shift
exec "$@"
""",
    "sudo": 'exec "$@"',
    "systemctl": r"""
echo "systemctl $*" >> "$STUB_LOG"
case "$*" in
  "start --no-block nixhost-nightly.service") [ -z "${STUB_NIGHTLY:-}" ] || "$STUB_NIGHTLY" ;;
  *"-P ActiveState"*) echo inactive ;;
  *"-P Result"*) echo "${STUB_RESULT:-success}" ;;
  list-jobs*) ;;
esac
""",
    "journalctl": 'echo "journalctl $*" >> "$STUB_LOG"; echo "==> a line from the build"',
    "curl": 'echo "curl $*" >> "$STUB_LOG"; cat "$STUB_POINTER"',
    "ship": 'echo "ship $*" >> "$STUB_LOG"',
    "sleep": "true",
}


def sh(*cmd, cwd):
    return subprocess.run(cmd, cwd=cwd, check=True, capture_output=True, text=True)


def lock(nixpkgs_modified):
    return json.dumps({
        "nodes": {
            "nixpkgs": {"locked": {"lastModified": nixpkgs_modified}},
            "root": {"inputs": {"nixpkgs": "nixpkgs"}},
        },
        "root": "root",
        "version": 7,
    }) + "\n"


@pytest.fixture
def env(tmp_path):
    bare = tmp_path / "nixhost.git"
    sh("git", "init", "--bare", "-b", "main", str(bare), cwd=tmp_path)
    work = tmp_path / "work"
    work.mkdir()
    sh("git", "init", "-b", "feat/x", cwd=work)
    for k, v in (("user.name", "t"), ("user.email", "t@t")):
        sh("git", "config", k, v, cwd=work)
    (work / "scripts").mkdir()
    for name in ("deploy.sh", "lock-check.sh"):
        (work / "scripts" / name).symlink_to(ROOT / "scripts" / name)
    (work / "flake.lock").write_text(lock(100))
    sh("git", "add", ".", cwd=work)
    sh("git", "commit", "-qm", "init", cwd=work)
    sh("git", "remote", "add", "nixhost", str(bare), cwd=work)

    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for name, body in STUBS.items():
        f = bin_dir / name
        f.write_text(f"#!/usr/bin/env bash\n{body}\n")
        f.chmod(0o755)
    pointer = tmp_path / "pointer"
    pointer.write_text(POINTER + "\n")
    log = tmp_path / "calls.log"
    log.write_text("")

    # What nixhost's nightly does to the repo: builds the tracked branch, bumps
    # the lock and publishes the result to nightly/htpc.
    nightly = tmp_path / "nightly"
    nightly.write_text(f"""#!/usr/bin/env bash
set -e
d=$(mktemp -d)
git clone -q -b feat/x {bare} "$d"
cd "$d"
echo bumped >> flake.lock
git -c user.name=n -c user.email=n@n commit -qam bump
git push -q -f origin HEAD:refs/heads/nightly/htpc
""")
    nightly.chmod(0o755)

    e = {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "STUB_LOG": str(log),
        "STUB_POINTER": str(pointer),
        "STUB_NIGHTLY": str(nightly),
        "DEPLOY_SHIP": str(bin_dir / "ship"),
        "DEPLOY_BRANCH": "feat/x",
        "DEPLOY_BUILDS": "htpc",
        "DEPLOY_CACHE_URL": "http://cache.test:8080",
        "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
        "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
    }

    class E:
        pass

    o = E()
    o.work, o.bare, o.tmp = work, bare, tmp_path

    def run(*flags, machine="htpc", **extra):
        return subprocess.run(
            [str(work / "scripts" / "deploy.sh"), machine, *flags], cwd=work,
            env={**e, **extra}, capture_output=True, text=True,
        )

    o.run = run
    o.calls = lambda: log.read_text().splitlines()
    o.ships = lambda: [c for c in o.calls() if c.startswith("ship")]
    o.head = lambda: sh("git", "rev-parse", "HEAD", cwd=work).stdout.strip()

    def remote(ref):
        r = subprocess.run(["git", "rev-parse", "--verify", "-q", ref], cwd=bare,
                           capture_output=True, text=True)
        return r.stdout.strip() if r.returncode == 0 else None

    o.remote = remote
    return o


def test_pushes_builds_on_nixhost_then_activates_the_result(env):
    r = env.run()
    assert r.returncode == 0, r.stderr
    assert env.remote("feat/x") == env.head()
    calls = env.calls()
    assert "systemctl start --no-block nixhost-nightly.service" in calls
    # The build's own log is followed, so a person sees it.
    assert any(c.startswith("journalctl") and "-f" in c for c in calls), calls
    assert "a line from the build" in r.stdout
    assert any("curl" in c and "http://cache.test:8080/pointers/htpc" in c for c in calls), calls
    assert env.ships() == [f"ship htpc --now --stage {POINTER}"]


def test_a_failed_build_activates_nothing(env):
    r = env.run(STUB_RESULT="exit-code")
    assert r.returncode != 0
    assert "exit-code" in r.stdout + r.stderr
    assert env.ships() == []


def test_a_result_not_built_on_the_push_activates_nothing(env):
    # Someone pushed in between, or the night's run published its own.
    other = env.tmp / "other"
    other.write_text(f"""#!/usr/bin/env bash
set -e
d=$(mktemp -d)
git clone -q -b feat/x {env.bare} "$d"
cd "$d"
git checkout -q --orphan elsewhere
git -c user.name=n -c user.email=n@n commit -qm elsewhere
git push -q -f origin HEAD:refs/heads/nightly/htpc
""")
    other.chmod(0o755)
    r = env.run(STUB_NIGHTLY=str(other))
    assert r.returncode != 0
    assert "not built on" in r.stderr
    assert env.ships() == []


def test_no_push_builds_and_stops(env):
    r = env.run("--no-push")
    assert r.returncode == 0, r.stderr
    assert "systemctl start --no-block nixhost-nightly.service" in env.calls()
    assert env.ships() == []


def test_another_branch_is_refused_before_anything_happens(env):
    sh("git", "checkout", "-qb", "feat/other", cwd=env.work)
    r = env.run()
    assert r.returncode != 0
    assert "feat/x" in r.stderr
    assert env.calls() == []
    assert env.remote("feat/other") is None and env.remote("feat/x") is None


def test_uncommitted_changes_are_refused(env):
    (env.work / "flake.lock").write_text(lock(200))
    r = env.run()
    assert r.returncode != 0
    assert "commit" in r.stderr
    assert env.calls() == []


def test_a_machine_nixhost_does_not_build_is_refused(env):
    r = env.run(machine="herdr")
    assert r.returncode != 0
    assert env.calls() == []


def test_warns_when_the_local_lock_is_older_than_the_published_one(env):
    # nixhost published a newer nixpkgs than this checkout has. If tonight's
    # full bump fails, the home-player-only retry builds on this lock.
    newer = env.tmp / "newer"
    sh("git", "clone", "-q", "-b", "feat/x", str(env.work), str(newer), cwd=env.tmp)
    (newer / "flake.lock").write_text(lock(500))
    sh("git", "-c", "user.name=n", "-c", "user.email=n@n", "commit", "-qam", "bump", cwd=newer)
    sh("git", "push", "-q", str(env.bare), "HEAD:refs/heads/nightly/htpc", cwd=newer)
    r = env.run("--no-push")
    assert r.returncode == 0, r.stderr
    assert "older than nixhost's nightly/htpc" in r.stderr
    assert "nixpkgs" in r.stderr


def test_no_warning_when_the_local_lock_is_current(env):
    r = env.run("--no-push")
    assert r.returncode == 0, r.stderr
    assert "older than" not in r.stderr
