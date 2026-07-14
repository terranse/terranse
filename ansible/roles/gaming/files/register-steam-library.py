#!/usr/bin/env python3
"""Register a Steam library folder without the UI.

Steam's Big Picture "add drive" button silently does nothing for a path it does
not consider a library, and Steam ships no CLI for this — so on a rebuilt VM the
games would quietly land on the small root disk instead of the pool.

A library is two things, not one:
  * a marker file `libraryfolder.vdf` in the library root, carrying a contentid;
  * an entry in `steamapps/libraryfolders.vdf` under the Steam install, keyed by
    an index and carrying the SAME contentid.
Create only the directory and Steam ignores it.

Steam rewrites libraryfolders.vdf when it exits, so this must run while Steam is
stopped, or the edit is discarded. Idempotent: re-running with a path that is
already registered changes nothing.

Managed by Ansible - do not edit manually.
"""

from __future__ import annotations

import argparse
import os
import random
import re
import sys
from pathlib import Path


def parse_entries(text: str) -> list[str]:
    """Return the existing "path" values in libraryfolders.vdf."""
    return re.findall(r'"path"\s+"([^"]+)"', text)


def next_index(text: str) -> int:
    indices = [int(i) for i in re.findall(r'^\s*"(\d+)"\s*$', text, re.MULTILINE)]
    return max(indices) + 1 if indices else 0


def render_entry(index: int, path: str, contentid: str, totalsize: int) -> str:
    return (
        f'\t"{index}"\n'
        "\t{\n"
        f'\t\t"path"\t\t"{path}"\n'
        '\t\t"label"\t\t""\n'
        f'\t\t"contentid"\t\t"{contentid}"\n'
        f'\t\t"totalsize"\t\t"{totalsize}"\n'
        '\t\t"update_clean_bytes_tally"\t\t"0"\n'
        '\t\t"time_last_update_verified"\t\t"0"\n'
        '\t\t"apps"\n'
        "\t\t{\n"
        "\t\t}\n"
        "\t}\n"
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--steam-root", required=True, help="Steam install dir (holds steamapps/)")
    ap.add_argument("--library", required=True, help="Library folder to register")
    ap.add_argument("--uid", type=int, default=None, help="chown created files to this uid")
    args = ap.parse_args()

    library = Path(args.library)
    steam_root = Path(args.steam_root)
    vdf = steam_root / "steamapps" / "libraryfolders.vdf"

    if not vdf.exists():
        # A VM that has never run Steam has no libraryfolders.vdf, and waiting for
        # a first launch would mean the pool is unregistered exactly when the first
        # game is installed. Seed the file with Steam's own install as entry 0;
        # Steam normalises it (and fixes the contentid) on next start.
        vdf.parent.mkdir(parents=True, exist_ok=True)
        vdf.write_text(
            '"libraryfolders"\n{\n'
            + render_entry(0, str(steam_root), str(random.getrandbits(63)), 0)
            + "}\n"
        )

    text = vdf.read_text()
    if str(library) in parse_entries(text):
        print(f"already registered: {library}")
        return 0

    (library / "steamapps").mkdir(parents=True, exist_ok=True)

    marker = library / "libraryfolder.vdf"
    contentid = str(random.getrandbits(63))
    if marker.exists():
        found = re.search(r'"contentid"\s+"(\d+)"', marker.read_text())
        if found:
            contentid = found.group(1)
    else:
        marker.write_text(
            '"libraryfolder"\n{\n'
            f'\t"contentid"\t\t"{contentid}"\n'
            '\t"label"\t\t""\n'
            "}\n"
        )

    stat = os.statvfs(library)
    totalsize = stat.f_blocks * stat.f_frsize

    entry = render_entry(next_index(text), str(library), contentid, totalsize)
    # Splice the entry in before the final closing brace of the top-level block.
    closing = text.rstrip().rfind("}")
    vdf.write_text(text[:closing] + entry + "}\n")

    if args.uid is not None:
        for p in (marker, library / "steamapps", vdf):
            try:
                os.chown(p, args.uid, args.uid)
            except OSError:
                pass

    print(f"registered: {library} (contentid={contentid}, {totalsize // 2**30} GiB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
