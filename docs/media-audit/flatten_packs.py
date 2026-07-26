#!/usr/bin/env python3
"""Flatten multi-film "pack" folders to the top level of the movies library.

Runs ON the media host (CT 106) via `ssh media.edholm.cc python3 -`.

Jellyfin expects `movies/<Title (Year)>/<file>`. When several films sit in
subfolders under one library-level folder it mis-assigns their identities, and
not randomly -- rotated, so it reads as plausible. All six films under
`Star Wars Hexalogy DTSHD[1080p]` were wrong: the *A New Hope* folder was
identified as *The Phantom Menace*, *Phantom Menace* as *Attack of the Clones*,
and so on round the cycle. `Terminator Trilogy[1080p]` had T1, T2 and T3 all
identified as *Terminator Salvation*, a film not even present.

Radarr cannot track a pack either -- it binds one movie per folder -- so
flattening fixes both at once.

Each subfolder is already named `Title(Year)[quality]`, so moving it up one level
is all that is required. Moves are renames within the same ZFS dataset: instant,
no data copied. A subfolder is skipped unless it holds at least one video, which
defers `Die Hard Collection[1080p]` until its archives are extracted.

Nothing is moved without --commit, and never over an existing target.
"""
import argparse
import json
import os
import re
import shutil
import sys

BASE = "/storage/movies"
VIDEXT = ('.mkv', '.mp4', '.avi', '.m4v', '.divx', '.iso', '.img', '.vob')

PACKS = [
    "Star Wars Hexalogy DTSHD[1080p]",
    "Harry Potter Collection[1080p]",
    "The Lord of the Rings Trilogy[1080p]",
    "Terminator Trilogy[1080p]",
    "Underworld Trilogy[720p]",
    "Resident Evil Collection[720p]",
    "Die Hard Collection[1080p]",
]

# Left alone deliberately:
#   Asterix   -- six top-level files with untranslated Swedish names
#                (kleopatra.mkv, britterna.mkv). Splitting them needs each film
#                identified first, which is a judgement call, not a move.
#   Konserter -- concert recordings, not films. They do not belong in the movies
#                library at all; flattening would scatter them through it.
SKIP = ("Asterix", "Konserter")


def has_video(folder):
    for root, dirs, files in os.walk(folder):
        for f in files:
            p = os.path.join(root, f)
            if f.lower().endswith(VIDEXT) and not re.search(r'sample', p, re.I):
                return True
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pack", action="append", help="repeatable; default all")
    ap.add_argument("--commit", action="store_true")
    ap.add_argument("--log", default=os.path.join(BASE, ".rar-trash", "flatten.log"))
    a = ap.parse_args()

    existing = {d.lower() for d in os.listdir(BASE)}
    plan, skipped = [], []
    for pack in (a.pack or PACKS):
        fp = os.path.join(BASE, pack)
        if not os.path.isdir(fp):
            skipped.append((pack, "pack folder missing"))
            continue
        for d in sorted(os.listdir(fp)):
            src = os.path.join(fp, d)
            if not os.path.isdir(src):
                continue
            if not has_video(src):
                skipped.append(("%s/%s" % (pack, d), "no video yet (still archived?)"))
                continue
            if d.lower() in existing:
                skipped.append(("%s/%s" % (pack, d), "target name already exists"))
                continue
            plan.append({"pack": pack, "src": src, "dst": os.path.join(BASE, d)})

    if a.commit:
        os.makedirs(os.path.dirname(a.log), exist_ok=True)
    log = open(a.log, "a") if a.commit else open(os.devnull, "w")
    moved = []
    for row in plan:
        # Re-check at the moment of the move; the earlier scan is a snapshot.
        if os.path.exists(row["dst"]):
            skipped.append((row["src"], "target appeared before move"))
            continue
        if a.commit:
            log.write("MOVE\t%s\t%s\n" % (row["src"], row["dst"]))
            log.flush()
            shutil.move(row["src"], row["dst"])
        moved.append(row)

    # A pack folder with nothing left but artwork has served its purpose.
    emptied = []
    for pack in {r["pack"] for r in moved}:
        fp = os.path.join(BASE, pack)
        if os.path.isdir(fp) and not any(
                os.path.isdir(os.path.join(fp, x)) for x in os.listdir(fp)):
            emptied.append(pack)

    print(json.dumps({"moved": [{"src": r["src"], "dst": r["dst"]} for r in moved],
                      "skipped": skipped,
                      "packs_now_without_subfolders": emptied,
                      "committed": a.commit}, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
