"""scripts/htpc-passwords.sh with stub op, mkpasswd and ssh: nothing real is touched."""

import os
import subprocess
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "htpc-passwords.sh"


def run(tmp_path, op_body):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    sent = tmp_path / "sent"
    for name, body in {
        "op": op_body,
        "mkpasswd": "printf 'HASH(%s)' \"$(cat)\"",
        # Records stdin only if ssh is reached at all.
        "ssh": f'cat > "{sent}"',
    }.items():
        f = bin_dir / name
        f.write_text(f"#!/usr/bin/env bash\n{body}\n")
        f.chmod(0o755)
    env = {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "HTPC_MKPASSWD": str(bin_dir / "mkpasswd"),
    }
    r = subprocess.run(
        [str(SCRIPT), "box"], env=env, capture_output=True, text=True
    )
    return r, sent


def test_good_run_sends_both_hashes(tmp_path):
    r, sent = run(tmp_path, 'case "$2" in *Vuxna*) echo pw1;; *) echo pw2;; esac')
    assert r.returncode == 0, r.stderr
    assert sent.read_text() == "vuxna:HASH(pw1)\nbarn:HASH(pw2)\n"


def test_failing_op_sends_nothing(tmp_path):
    r, sent = run(tmp_path, "echo pw1; [[ $2 == *Vuxna* ]] || exit 1")
    assert r.returncode != 0
    assert not sent.exists()


def test_empty_secret_sends_nothing_and_is_not_echoed(tmp_path):
    r, sent = run(tmp_path, 'case "$2" in *Vuxna*) echo pw1;; *) echo;; esac')
    assert r.returncode != 0
    assert not sent.exists()
    assert "HTPC Barn" in r.stderr and "pw1" not in r.stderr
