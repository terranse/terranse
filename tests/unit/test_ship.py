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
