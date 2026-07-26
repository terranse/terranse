#!/usr/bin/env python3
"""Rewrite the corrupt episode NFOs in the TV library.

Runs ON the media host (CT 106) via `ssh media.edholm.cc python3 -`.

Ten series carry NFOs that contradict reality -- Band of Brothers' ten episodes
all declare `S20E01`, 63 of The Clone Wars' 117 declare a season but no episode
at all. The TV library has `LocalMetadataReaderOrder: ["Nfo"]`, so Jellyfin
believes them over the filenames, and its season/episode display matches the
corruption exactly.

Simply deleting the bad NFOs would make it worse: these releases predate
`SxxExx` naming. Their files are `Part06.avi`, `...3of6.Jungles...`,
`Planet.Dinosaur.III...`, `...Del.3.av.3...` -- nothing Jellyfin's fallback
parser can turn into an episode number. So each series gets an explicit rule
mapping its own naming scheme to a real season/episode, and the NFOs are
rewritten rather than removed.

Episode *titles* come from Sonarr wherever Sonarr has the series identified
correctly (`trust_sonarr`). For the series Sonarr itself has wrong -- it thinks
`Pixar Short Film Collection` is *British Transport Films* and
`Dinosauriernas Planet` is *Hunter x Hunter* -- titles are derived from the
filename instead, because Sonarr's episode list would be for the wrong show.

Old NFOs are moved to <lib>/.nfo-trash/ rather than deleted. Nothing is written
without --commit.
"""
import argparse
import json
import os
import re
import shutil
import sys
import urllib.request
import xml.sax.saxutils as sax

BASE = "/storage/tv_series"
TRASH = ".nfo-trash"
VIDEXT = ('.mkv', '.mp4', '.avi', '.m4v', '.divx')
SK = "271ab53c333c4aa49a8748fe13d32782"

ROMAN = {"i": 1, "ii": 2, "iii": 3, "iv": 4, "v": 5, "vi": 6,
         "vii": 7, "viii": 8, "ix": 9, "x": 10}


# Tokens that mark a fragment as release metadata rather than an episode title.
JUNK = re.compile(r'\b(?:www|ac3|aac|dd5|divx5?|xvid|x26[45]|h26[45]|hdtv|dvdrip|'
                  r'bluray|brrip|webrip|web-?dl|720p|1080p|2160p|mvgroup|org|com|'
                  r'custom|swesub|swedish|nordic|repack|internal|proper)\b', re.I)

SMALL = {"a", "an", "and", "the", "of", "or", "in", "on", "at", "to", "for",
         "with", "from", "by", "as"}


def clean(s):
    """Turn a dotted release fragment into something readable."""
    s = re.sub(r'[._]+', ' ', s).strip()
    return re.sub(r'\s+', ' ', s)


def is_junk(t):
    """True when a candidate title is really leftover release tags."""
    return not t or bool(JUNK.search(t))


def titlecase(s):
    words = s.split()
    out = []
    for i, w in enumerate(words):
        out.append(w if any(c.isupper() for c in w)
                   else (w.lower() if i and w.lower() in SMALL else w.capitalize()))
    return " ".join(out)


# --------------------------------------------------------------- per-series map
# Each rule returns (season, [episode, ...], title_or_None) for one video file,
# or None to leave that file alone.

def r_band_of_brothers(rel, name):
    m = re.search(r'\.E(\d{2})\.', name)
    if not m:
        return None
    title = re.sub(r'\.720p.*$', '', name.split('.E%s.' % m.group(1), 1)[1])
    return 1, [int(m.group(1))], clean(title)


def r_planet_earth2(rel, name):
    m = re.search(r'\.(\d)of6\.([A-Za-z]+)\.', name)
    return (1, [int(m.group(1))], m.group(2)) if m else None


def r_spartacus(rel, name):
    # This folder holds Spartacus: Gods of the Arena, which is season 0 of
    # tvdb 129261 -- Sonarr lists exactly these six as S00E01-E06.
    m = re.search(r'\.E(\d{2})\.', name)
    return (0, [int(m.group(1))], None) if m else None


def r_clone_wars(rel, name):
    d = os.path.dirname(rel)
    ms = re.search(r'Season\s*(\d+)', d)
    # Season 4 and 5 already carry SxxExx in the filename.
    mf = re.search(r'[Ss](\d{2})[Ee](\d{2})(?:-?[Ee](\d{2}))?', name)
    if mf:
        eps = [int(mf.group(2))] + ([int(mf.group(3))] if mf.group(3) else [])
        return int(mf.group(1)), eps, None
    if not ms:
        return None
    # Seasons 1-3 are "E14 Witches of the Mist.avi", sometimes "E01-E02 A & B".
    me = re.match(r'E(\d{2})(?:-E(\d{2}))?\s+(.*?)\.(?:avi|mp4|mkv)$', name, re.I)
    if not me:
        return None
    eps = [int(me.group(1))] + ([int(me.group(2))] if me.group(2) else [])
    return int(ms.group(1)), eps, me.group(3).strip()


def r_planet_dinosaur(rel, name):
    m = re.search(r'Planet\.Dinosaur\.([IVX]+)\.', name)
    return (1, [ROMAN[m.group(1).lower()]], None) if m else None


def r_wwd_swedish(rel, name):
    if re.match(r'Bonus\.', name, re.I):
        return 0, [1], "Bonus"
    m = re.match(r'Part(\d{2})\.', name, re.I)
    return (1, [int(m.group(1))], None) if m else None


def r_walking_with(rel, name):
    # Four distinct BBC series stacked as seasons 1-4 by directory prefix.
    d = os.path.dirname(rel)
    ms = re.match(r'(\d)\s*-\s*(.+)$', d)
    if not ms:
        return None
    season = int(ms.group(1))
    for pat in (r'-EP(\d+)\.', r'^Ep\s*(\d+)\s*-', r'\((\d+)-\d+\)', r'\.(\d)of\d\.'):
        m = re.search(pat, name, re.I)
        if m:
            t = None
            mt = re.search(r'-\s*([^-.][^-]*?)\.(?:avi|mp4|mkv)$', name)
            if mt:
                t = clean(mt.group(1))
                # "...-EP2.avi" leaves "EP2" -- the number again, not a title --
                # and the Cavemen files leave "AC3 www mvgroup org". Drop both so
                # the provider supplies the real title.
                if re.fullmatch(r'(?:ep|part|pt)\s*\d+', t, re.I) or is_junk(t):
                    t = None
            return season, [int(m.group(1))], t
    return None


def r_dinosauriernas(rel, name):
    m = re.search(r'Del\.(\d+)\.av\.\d+\.(.+?)\.SWEDiSH', name, re.I)
    return (1, [int(m.group(1))], clean(m.group(2))) if m else None


def r_krigets(rel, name):
    m = re.search(r'[Ee](\d{2})\.', name)
    return (1, [int(m.group(1))], None) if m else None


def r_pixar(rel, name):
    """Pixar shorts have no episode numbering at all -- order them by the year
    in the filename, which is how the TVDB entry is ordered. The three
    Despicable Me minions shorts in here are not Pixar and are left alone."""
    if re.match(r'Despicable\.Me', name, re.I):
        return None
    m = re.match(r'(.+?)\.((?:19|20)\d\d)\.', name)
    if not m:
        return None
    # Keep the filename title rather than letting the provider fill it: the
    # episode numbers below are our own chronological ordering and may not line
    # up with TVDB's, so a provider title could land on the wrong short.
    return 1, None, titlecase(clean(m.group(1)))  # episode filled in by caller


RULES = {
    "Band Of Brothers [720p]":            dict(fn=r_band_of_brothers, sonarr=4, trust_sonarr=True),
    "BBC Planet Earth II":                dict(fn=r_planet_earth2, sonarr=5, trust_sonarr=True),
    "Spartacus Blood and Sand(2010)":     dict(fn=r_spartacus, sonarr=38, trust_sonarr=True),
    "Star Wars - The Clone Wars":         dict(fn=r_clone_wars, sonarr=41, trust_sonarr=True),
    "Planet Dinosaur(2011)[720p]":        dict(fn=r_planet_dinosaur, sonarr=33, trust_sonarr=False),
    "Walking with Dinosaurs - Swedish(1999)[XviD]": dict(fn=r_wwd_swedish, sonarr=50, trust_sonarr=False),
    "Walking with... Monsters, Dinosaurs, Beasts, Cavemen": dict(fn=r_walking_with, sonarr=51, trust_sonarr=False),
    "Dinosauriernas Planet (2011)":       dict(fn=r_dinosauriernas, sonarr=11, trust_sonarr=False),
    "Krigets Unga Hjärtan":               dict(fn=r_krigets, sonarr=23, trust_sonarr=False),
    "Pixar Short Film Collection [1080p]": dict(fn=r_pixar, sonarr=32, trust_sonarr=False, order_by_year=True),
}

# Breaking Bad is handled separately: its episode filenames parse fine
# ("Season 3 Episode 11 - Abiquiu.avi"), only the Extras/ NFOs are clones.
BREAKING_BAD = "Breaking bad"


def sonarr_titles(series_id):
    r = urllib.request.Request(
        "http://localhost:8989/api/v3/episode?seriesId=%d" % series_id,
        headers={"X-Api-Key": SK})
    out = {}
    for e in json.load(urllib.request.urlopen(r, timeout=120)):
        out[(e["seasonNumber"], e["episodeNumber"])] = e.get("title")
    return out


def nfo_body(entries):
    """One <episodedetails> per episode; several in one file marks a multi-episode
    video, which is the Kodi/Jellyfin convention."""
    out = ['<?xml version="1.0" encoding="utf-8" standalone="yes"?>']
    for season, ep, title in entries:
        out.append("<episodedetails>")
        if title:
            out.append("  <title>%s</title>" % sax.escape(title))
        out.append("  <season>%d</season>" % season)
        out.append("  <episode>%d</episode>" % ep)
        out.append("</episodedetails>")
    return "\n".join(out) + "\n"


def videos_in(folder):
    out = []
    for root, dirs, files in os.walk(folder):
        dirs[:] = [d for d in dirs if d != TRASH]
        for f in sorted(files):
            p = os.path.join(root, f)
            if f.lower().endswith(VIDEXT) and not re.search(r'sample', p, re.I):
                out.append(os.path.relpath(p, folder))
    return sorted(out)


def trash_old_nfos(folder, name, commit, log, only_under=None, keep=()):
    """Move episode NFOs aside. `keep` protects the NFOs of videos we chose not
    to renumber -- stripping those would leave them with no numbering at all,
    which is worse than the wrong numbering they have."""
    moved = 0
    keep = {os.path.normpath(k) for k in keep}
    for root, dirs, files in os.walk(folder):
        dirs[:] = [d for d in dirs if d != TRASH]
        for f in files:
            if not f.lower().endswith(".nfo"):
                continue
            p = os.path.join(root, f)
            if os.path.normpath(p) in keep:
                continue
            if only_under and only_under not in os.path.relpath(p, folder):
                continue
            try:
                if "<episodedetails" not in open(p, encoding="utf-8", errors="replace").read():
                    continue
            except OSError:
                continue
            if commit:
                tp = os.path.join(BASE, TRASH, os.path.relpath(p, BASE))
                os.makedirs(os.path.dirname(tp), exist_ok=True)
                log.write("MOVE\t%s\t%s\n" % (p, tp))
                log.flush()
                shutil.move(p, tp)
            moved += 1
    return moved


def run(name, commit, log):
    cfg = RULES[name]
    folder = os.path.join(BASE, name)
    rep = {"series": name, "written": [], "unmatched": [], "trashed_nfos": 0}
    titles = sonarr_titles(cfg["sonarr"]) if cfg["trust_sonarr"] else {}

    plan = []
    for rel in videos_in(folder):
        res = cfg["fn"](rel, os.path.basename(rel))
        if not res:
            rep["unmatched"].append(rel)
            continue
        plan.append([rel] + list(res))

    if cfg.get("order_by_year"):
        # Pixar: number the shorts chronologically by the year in the filename.
        def yr(row):
            m = re.search(r'\.((?:19|20)\d\d)\.', os.path.basename(row[0]))
            return int(m.group(1)) if m else 9999
        plan.sort(key=yr)
        for i, row in enumerate(plan, 1):
            row[2] = [i]

    keep = [os.path.join(folder, os.path.splitext(rel)[0] + ".nfo")
            for rel in rep["unmatched"]]
    rep["trashed_nfos"] = trash_old_nfos(folder, name, commit, log, keep=keep)

    for rel, season, eps, title in plan:
        entries = []
        for ep in eps:
            t = titles.get((season, ep)) or title
            entries.append((season, ep, t))
        target = os.path.join(folder, os.path.splitext(rel)[0] + ".nfo")
        rep["written"].append({"nfo": os.path.relpath(target, folder),
                               "eps": ["S%02dE%02d" % (s, e) for s, e, _ in entries],
                               "title": entries[0][2]})
        if commit:
            body = nfo_body(entries)
            with open(target, "w", encoding="utf-8") as fh:
                fh.write(body)
            st = os.stat(os.path.dirname(target))
            try:
                os.chmod(target, 0o660)
                os.chown(target, st.st_uid, st.st_gid)
            except PermissionError:
                pass
            log.write("WRITE\t%s\n" % target)
            log.flush()
    return rep


def run_breaking_bad(commit, log):
    folder = os.path.join(BASE, BREAKING_BAD)
    n = trash_old_nfos(folder, BREAKING_BAD, commit, log, only_under="Extras")
    return {"series": BREAKING_BAD, "trashed_nfos": n, "written": [],
             "unmatched": [],
             "note": "Extras/ NFOs only; episode filenames parse natively"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--series", action="append", help="repeatable; default all")
    ap.add_argument("--commit", action="store_true")
    ap.add_argument("--log", default=os.path.join(BASE, TRASH, "fix_nfo.log"))
    a = ap.parse_args()

    names = a.series or (list(RULES) + [BREAKING_BAD])
    if a.commit:
        os.makedirs(os.path.dirname(a.log), exist_ok=True)
    log = open(a.log, "a") if a.commit else open(os.devnull, "w")
    reps = []
    for n in names:
        print("  -> %s" % n, file=sys.stderr)
        reps.append(run_breaking_bad(a.commit, log) if n == BREAKING_BAD
                    else run(n, a.commit, log))
    log.close()
    print(json.dumps(reps, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
