"""scripts/prune-cache.sh against a throwaway file:// cache: what it keeps,
what it removes, and that it stays quick on a cache the size of nixhost's."""

import os
import subprocess
import time
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "prune-cache.sh"


def h(n: int) -> str:
    """A 32-character store hash, distinct per n."""
    return f"{n:032d}"


def narinfo(cache: Path, n: int, refs=(), nar=None, name="pkg"):
    nar = nar or f"nar/{h(n)}.nar.zst"
    refs_line = " ".join(f"{h(r)}-{name}" for r in refs)
    (cache / f"{h(n)}.narinfo").write_text(
        f"StorePath: /nix/store/{h(n)}-{name}\nURL: {nar}\n"
        f"Compression: zstd\nReferences: {refs_line}\n"
    )
    (cache / nar).parent.mkdir(exist_ok=True)
    (cache / nar).write_bytes(b"x")


def pointers(cache: Path, machine: str, ns):
    (cache / "pointers").mkdir(exist_ok=True)
    (cache / "pointers" / f"{machine}.history").write_text(
        "".join(f"/nix/store/{h(n)}-nixos-system\n" for n in ns)
    )


def run(cache: Path, keep=None):
    env = {**os.environ, "NIX_CACHE_DIR": str(cache)}
    if keep is not None:
        env["CACHE_KEEP"] = str(keep)
    return subprocess.run(
        ["bash", str(SCRIPT)], env=env, capture_output=True, text=True, check=True
    )


def narinfos(cache: Path):
    return {p.name.removesuffix(".narinfo") for p in cache.glob("*.narinfo")}


def nars(cache: Path):
    return {str(p.relative_to(cache)) for p in (cache / "nar").rglob("*") if p.is_file()}


def test_keeps_the_closures_of_the_last_pointers_and_removes_the_rest(tmp_path):
    # 1..3 are old systems, 4 and 5 recent; 10 is shared, 11 only old, 12 deep.
    narinfo(tmp_path, 12)
    narinfo(tmp_path, 10, refs=[12, 10])  # a self-reference, as Nix writes them
    narinfo(tmp_path, 11)
    for n in (1, 2, 3):
        narinfo(tmp_path, n, refs=[10, 11])
    narinfo(tmp_path, 4, refs=[10])
    narinfo(tmp_path, 5, refs=[10, 12])
    narinfo(tmp_path, 99)  # reachable from nothing
    pointers(tmp_path, "htpc", [1, 2, 3, 4, 5])

    out = run(tmp_path, keep=2).stdout

    assert narinfos(tmp_path) == {h(n) for n in (4, 5, 10, 12)}
    assert nars(tmp_path) == {f"nar/{h(n)}.nar.zst" for n in (4, 5, 10, 12)}
    assert "kept 4 paths, removed 5 narinfo and 5 nar files" in out


def test_every_machine_keeps_its_own_last_pointers(tmp_path):
    narinfo(tmp_path, 1)
    narinfo(tmp_path, 2)
    narinfo(tmp_path, 3)
    pointers(tmp_path, "htpc", [3, 1])
    pointers(tmp_path, "nixhost", [3, 2])

    run(tmp_path, keep=1)

    assert narinfos(tmp_path) == {h(1), h(2)}


def test_a_nar_shared_by_two_narinfos_stays_while_one_is_kept(tmp_path):
    narinfo(tmp_path, 1, nar="nar/same.nar.zst")
    narinfo(tmp_path, 2, nar="nar/same.nar.zst")
    pointers(tmp_path, "htpc", [1])

    run(tmp_path, keep=1)

    assert narinfos(tmp_path) == {h(1)}
    assert nars(tmp_path) == {"nar/same.nar.zst"}


def test_a_missing_narinfo_in_the_closure_is_skipped(tmp_path):
    narinfo(tmp_path, 1, refs=[2])  # 2 was never published
    pointers(tmp_path, "htpc", [1])

    run(tmp_path, keep=1)

    assert narinfos(tmp_path) == {h(1)}


def test_no_history_is_nothing_to_do(tmp_path):
    narinfo(tmp_path, 1)

    assert "nothing to do" in run(tmp_path).stdout
    assert narinfos(tmp_path) == {h(1)}


def test_history_is_trimmed_to_four_times_keep(tmp_path):
    narinfo(tmp_path, 1)
    pointers(tmp_path, "htpc", [1] * 30)

    run(tmp_path, keep=2)

    assert len((tmp_path / "pointers" / "htpc.history").read_text().splitlines()) == 8


def test_a_cache_the_size_of_nixhosts_prunes_in_seconds(tmp_path):
    # ~4000 paths, each referring to 25 others: nixhost's cache took 3.5 min.
    total = 4000
    for n in range(total):
        narinfo(tmp_path, n, refs=[(n * 7 + k * 13) % total for k in range(25)])
    for n in range(total, total + 500):
        narinfo(tmp_path, n)  # unreachable
    pointers(tmp_path, "htpc", range(5))

    started = time.monotonic()
    out = run(tmp_path).stdout
    took = time.monotonic() - started

    assert "removed 500 narinfo" in out
    assert took < 15, f"prune took {took:.1f}s"
