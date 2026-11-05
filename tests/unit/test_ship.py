"""scripts/ship.sh failure paths with stub nix, ssh and df: nothing real is touched."""

import os
import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "ship.sh"


def run(tmp_path, flags, ssh_body, nix_copy_fails=False, wait="2"):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    cache = tmp_path / "cache"
    cache.mkdir()
    nix = (
        'case "$1" in\n'
        '  build) echo /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-x ;;\n'
        f'  copy) case "$*" in *ssh-ng*) exit {1 if nix_copy_fails else 0} ;; esac ;;\n'
        "esac\n"
    )
    for name, body in {"nix": nix, "ssh": ssh_body, "sleep": "true"}.items():
        f = bin_dir / name
        f.write_text(f"#!/usr/bin/env bash\n{body}\n")
        f.chmod(0o755)
    env = {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "NIX_CACHE_DIR": str(cache),
        "MIN_FREE_MB": "1",
        "SSH_WAIT_SECONDS": wait,
        "TFVARS": str(tmp_path / "none"),
    }
    r = subprocess.run(
        [str(SCRIPT), "htpc", *flags], env=env, capture_output=True, text=True
    )
    return r, cache


@pytest.mark.parametrize(
    "case", ["unreachable", "push-fails", "stage-fails", "no-htpc-stage"]
)
@pytest.mark.parametrize("now", [True, False])
def test_failure_paths(tmp_path, case, now):
    ssh = {
        "unreachable": "exit 255",
        "push-fails": "exit 0",
        "stage-fails": 'case "$*" in *"sudo "*) exit 1 ;; esac',
        "no-htpc-stage": 'case "$*" in *"test -x"*) exit 1 ;; esac',
    }[case]
    r, cache = run(
        tmp_path, ["--now"] if now else [], ssh, case == "push-fails", wait="1"
    )
    # The pointer stands in every case.
    assert (cache / "pointers" / "htpc").exists()
    if now:
        assert r.returncode == 1, r.stderr
        assert "NOT activated; it will wait for the next night window" in r.stderr
    else:
        assert r.returncode == 0, r.stderr
        assert "next activation window" in r.stdout


def test_success_with_now_still_exits_zero(tmp_path):
    r, _ = run(tmp_path, ["--now"], "exit 0")
    assert r.returncode == 0, r.stderr
    assert "activating now" in r.stdout


STAGED = "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-nixos-system-htpc"


def run_stage(tmp_path, flags, ssh_body="exit 0"):
    """--stage: the closure is already published; only the box's part runs."""
    log = tmp_path / "calls.log"
    log.write_text("")
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for name, body in {
        "nix": f'echo "nix $*" >> {log}',
        "ssh": f'echo "ssh $*" >> {log}\n{ssh_body}',
        "sleep": "true",
    }.items():
        f = bin_dir / name
        f.write_text(f"#!/usr/bin/env bash\n{body}\n")
        f.chmod(0o755)
    env = {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        # Nowhere: a stage-only run must not need a cache on this machine.
        "NIX_CACHE_DIR": str(tmp_path / "no-cache"),
        "SSH_WAIT_SECONDS": "1",
        "TFVARS": str(tmp_path / "none"),
    }
    r = subprocess.run(
        [str(SCRIPT), "htpc", *flags], env=env, capture_output=True, text=True
    )
    return r, log.read_text().splitlines()


def test_stage_builds_and_publishes_nothing(tmp_path):
    r, calls = run_stage(tmp_path, ["--now", "--stage", STAGED])
    assert r.returncode == 0, r.stderr
    assert not [c for c in calls if c.startswith("nix")], calls
    assert not (tmp_path / "no-cache").exists()
    # The box fetches the closure itself, from the cache it is configured with,
    # then the urgent path: htpc-stage --now.
    assert any(c.endswith(f"nix-store --realise {STAGED}") for c in calls), calls
    assert any(c.endswith(f"sudo /run/current-system/sw/bin/htpc-stage --now {STAGED}") for c in calls), calls


def test_stage_on_a_box_that_cannot_fetch_is_not_activated(tmp_path):
    r, _ = run_stage(
        tmp_path, ["--now", "--stage", STAGED],
        'case "$*" in *"nix-store --realise"*) exit 1 ;; esac',
    )
    assert r.returncode == 1
    assert "NOT activated" in r.stderr


@pytest.mark.parametrize(
    "bad", ["", "not-a-path", "/nix/store/short", STAGED + "/bin", STAGED + "\n/nix/store/x"]
)
def test_stage_refuses_anything_but_one_store_path(tmp_path, bad):
    r, calls = run_stage(tmp_path, ["--now", "--stage", bad])
    assert r.returncode != 0
    assert not [c for c in calls if c.startswith("ssh")], calls


def test_stage_with_no_push_is_refused(tmp_path):
    r, calls = run_stage(tmp_path, ["--now", "--no-push", "--stage", STAGED])
    assert r.returncode == 2
    assert not calls
