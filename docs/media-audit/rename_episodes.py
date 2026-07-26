#!/usr/bin/env python3
"""Rename the episode files Jellyfin cannot read correctly from an NFO.

Runs ON the media host (CT 106) via `ssh media.edholm.cc python3 -`.

Jellyfin derives season and episode from the filename in preference to the NFO,
and it reads a bare four-digit year as SxxExx: `Planet.Dinosaur.III.2011...`
becomes S20E11, `luxo.jr.1986...` becomes S19E86, and Walking with Beasts'
`(3-6)` becomes season 3 by luck of the pattern rather than intent. For those
files an NFO cannot win -- verified by writing correct NFOs *and* moving them
into a real `Season 01/` folder, neither of which changed the result.

Inserting an explicit `SxxExx` does win. Season, episode and title come from the
NFO that fix_nfo.py already wrote, so this only re-expresses what is already
recorded, in the one place Jellyfin trusts.

Sibling `.nfo` and `.srt` files are renamed alongside so they stay associated.
Every rename is logged. Nothing happens without --commit.
"""
import argparse
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

BASE = "/storage/tv_series"
VIDEXT = ('.mkv', '.mp4', '.avi', '.m4v', '.divx')
SIDECARS = ('.nfo', '.srt', '.sub', '.idx', '.ass')

# folder (relative to BASE) -> show name used in the new filename
GROUPS = {
    "Planet Dinosaur(2011)[720p]": "Planet Dinosaur",
    "Pixar Short Film Collection [1080p]": "Pixar Short Films",
    "Walking with... Monsters, Dinosaurs, Beasts, Cavemen/3 - Beasts": "Walking with Beasts",
}

# fix_nfo.py deliberately did not renumber these -- they are Illumination
# minions shorts misfiled under Pixar -- so their NFOs still hold the old bogus
# S20E13. Renaming from those would give three files the same episode number and
# stamp a wrong show name onto them.
EXCLUDE = re.compile(r'^Despicable\.Me', re.I)

BAD = re.compile(r'[\\/:*?"<>|]')


def read_nfo(path):
    """(season, episode, title) from an episodedetails NFO, or None."""
    try:
        raw = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return None
    if "<episodedetails" not in raw:
        return None
    # A multi-episode NFO holds several roots; wrap so ElementTree can parse it.
    try:
        root = ET.fromstring("<r>%s</r>" % re.sub(r'<\?xml[^>]*\?>', '', raw))
    except ET.ParseError:
        return None
    eds = root.findall("episodedetails")
    if not eds:
        return None
    def num(el, tag):
        t = el.findtext(tag)
        return int(t) if t and t.strip().isdigit() else None
    season = num(eds[0], "season")
    eps = [num(e, "episode") for e in eds]
    title = (eds[0].findtext("title") or "").strip() or None
    if season is None or any(e is None for e in eps):
        return None
    return season, eps, title


def new_stem(show, season, eps, title):
    tag = "S%02dE%02d" % (season, eps[0])
    for e in eps[1:]:
        tag += "-E%02d" % e
    stem = "%s - %s" % (show, tag)
    if title:
        stem += " - %s" % title
    return BAD.sub("", stem).rstrip(" .")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--commit", action="store_true")
    ap.add_argument("--log", default=os.path.join(BASE, ".nfo-trash", "rename.log"))
    a = ap.parse_args()

    plan, skipped = [], []
    for rel, show in GROUPS.items():
        folder = os.path.join(BASE, rel)
        if not os.path.isdir(folder):
            skipped.append((rel, "folder missing"))
            continue
        for root, dirs, files in os.walk(folder):
            for f in sorted(files):
                if not f.lower().endswith(VIDEXT):
                    continue
                src = os.path.join(root, f)
                if re.search(r'[Ss]\d{2}[Ee]\d{2}', f):
                    skipped.append((os.path.relpath(src, BASE), "already has SxxExx"))
                    continue
                if EXCLUDE.match(f):
                    skipped.append((os.path.relpath(src, BASE),
                                    "excluded: not part of this show"))
                    continue
                stem, ext = os.path.splitext(f)
                meta = read_nfo(os.path.join(root, stem + ".nfo"))
                if not meta:
                    skipped.append((os.path.relpath(src, BASE), "no usable NFO"))
                    continue
                ns = new_stem(show, *meta)
                group = [(src, os.path.join(root, ns + ext))]
                for sc in SIDECARS:
                    old = os.path.join(root, stem + sc)
                    if os.path.exists(old):
                        group.append((old, os.path.join(root, ns + sc)))
                clash = [d for _, d in group if os.path.exists(d)]
                if clash:
                    skipped.append((os.path.relpath(src, BASE), "target exists: %s"
                                    % os.path.basename(clash[0])))
                    continue
                plan.append({"show": show, "renames": group})

    # Two files in one show resolving to the same SxxExx means a source NFO is
    # untrustworthy, not that the rename is ready. Refuse the whole run rather
    # than silently stamp duplicates onto the library.
    seen = {}
    for item in plan:
        key = (item["show"], os.path.basename(item["renames"][0][1]).split(" - ")[1])
        seen.setdefault(key, []).append(os.path.basename(item["renames"][0][0]))
    dupes = {"%s %s" % k: v for k, v in seen.items() if len(v) > 1}
    if dupes:
        print(json.dumps({"error": "duplicate episode numbers; refusing to rename",
                          "duplicates": dupes}, indent=1, ensure_ascii=False))
        sys.exit(1)

    if a.commit:
        os.makedirs(os.path.dirname(a.log), exist_ok=True)
    log = open(a.log, "a") if a.commit else open(os.devnull, "w")
    done = []
    for item in plan:
        for src, dst in item["renames"]:
            if os.path.exists(dst):          # re-check at the moment of the move
                skipped.append((src, "target appeared before rename"))
                continue
            if a.commit:
                log.write("RENAME\t%s\t%s\n" % (src, dst))
                log.flush()
                os.rename(src, dst)
        done.append({"show": item["show"],
                     "from": os.path.basename(item["renames"][0][0]),
                     "to": os.path.basename(item["renames"][0][1]),
                     "sidecars": len(item["renames"]) - 1})
    log.close()
    print(json.dumps({"renamed": done, "skipped": skipped, "committed": a.commit},
                     indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
