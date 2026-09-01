#!/usr/bin/env python3
"""Extract the library's unextracted RAR sets and retire the parts safely.

Runs ON the media host (CT 106), driven over `ssh media.edholm.cc python3 -`.

Three phases per archive set, each gating the next:

  verify   `unrar t` -- full CRC across every volume. Read-only.
  extract  `unrar x -o-` into the archive's own directory. Never overwrites.
  trash    move the parts to <lib>/.rar-trash/ once every gate passes.

Deliberately uses the **qbittorrent container's UNRAR 7.20**, not the host's
`/usr/bin/unrar`. The host binary is unrar-free 0.3.1, which cannot follow a
multi-volume set: on an 11-volume archive it writes only the first volume,
prints "Truncated RAR file data" and "Failed", and still exits 0. Gating
deletion on that exit code would destroy the archives after a failed extract.

Nothing is written without --commit. Parts are never removed, only moved within
the same ZFS dataset (an instant rename), because this media has no backup and
the datasets have no snapshots.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.parse
import urllib.request

LIBS = {"movies": "/storage/movies", "tv_series": "/storage/tv_series"}
TRASH = ".rar-trash"
VIDEXT = ('.mkv', '.mp4', '.avi', '.m4v', '.mov', '.wmv', '.mpg', '.mpeg',
          '.ts', '.divx', '.m2ts', '.iso', '.img', '.vob')
SKIP_DIRS = ('.torrents', 'System Volume Information', TRASH)
RARANY = re.compile(r'\.(rar|r\d\d|s\d\d|\d{3})$', re.I)
PARTVOL = re.compile(r'\.part\d+\.rar$', re.I)
PARTONE = re.compile(r'\.part0*1\.rar$', re.I)


def is_incomplete_marker(name):
    """A leftover from an aborted download, meaning the archive set is suspect.

    Matched precisely, not by substring: an earlier version tested `'.part' in
    name`, which flagged every `*.part01.rar` volume and so falsely blocked
    `Die Hard Collection` and `The Hunger Games Mockingjay Part 2` -- the second
    only because the film's title contains the word "part".
    """
    return ("uTorrentPartFile" in name
            or name.endswith(".!qB")
            or name.endswith(".part"))


# ---------------------------------------------------------------- unrar (in qb)

def unrar(args, timeout=7200, as_uid=None):
    """Run unrar inside the qbittorrent container. Paths must be /media/... .

    as_uid ("1000:1000") extracts as that user so output lands owned correctly.
    unrar in the container is root by default, which would leave the extracted
    file root:root 0644 while every sibling in the library is 1000:1000 0670.
    """
    pre = ["docker", "exec"] + (["-u", as_uid] if as_uid else []) + ["qbittorrent", "unrar"]
    return subprocess.run(pre + args, capture_output=True, text=True, timeout=timeout)


def owner_of(path):
    """"uid:gid" of `path`, so extracted files inherit the library's convention."""
    st = os.stat(path)
    return "%d:%d" % (st.st_uid, st.st_gid)


def cpath(host_path):
    """Host /storage/X -> the path qbittorrent sees, /media/X."""
    assert host_path.startswith("/storage/"), host_path
    return "/media/" + host_path[len("/storage/"):]


def listing(main):
    """[(name, size)] the archive claims to contain, from `unrar lt`."""
    r = unrar(["lt", cpath(main)], timeout=600)
    out, name = [], None
    for line in r.stdout.splitlines():
        line = line.strip()
        if line.startswith("Name:"):
            name = line.split(":", 1)[1].strip()
        elif line.startswith("Size:") and name is not None:
            try:
                out.append((name, int(line.split(":", 1)[1].strip())))
            except ValueError:
                pass
            name = None
    return out, r.returncode


# ---------------------------------------------------------------- set discovery

def volumes_of(main):
    """Every part file belonging to the set whose first volume is `main`.

    Enumerated from the stem rather than globbed, so a folder holding several
    sets (Die Hard Collection, Heroes) never mixes them up.
    """
    d, b = os.path.dirname(main), os.path.basename(main)
    if PARTVOL.search(b):
        stem = PARTVOL.sub("", b)
        pat = re.compile(re.escape(stem) + r'\.part\d+\.rar$', re.I)
    elif b.lower().endswith(".rar"):
        stem = b[:-4]
        pat = re.compile(re.escape(stem) + r'\.(rar|r\d\d|s\d\d)$', re.I)
    elif re.search(r'\.001$', b):
        stem = b[:-4]
        pat = re.compile(re.escape(stem) + r'\.\d{3}$')
    else:
        return [main]
    return sorted(os.path.join(d, f) for f in os.listdir(d) if pat.fullmatch(f))


def find_sets(folder):
    """First volumes inside `folder`, plus whether any video already exists."""
    mains, rars, vids, partial = [], [], [], []
    for root, dirs, files in os.walk(folder):
        dirs[:] = [x for x in dirs if x not in SKIP_DIRS]
        for f in files:
            p = os.path.join(root, f)
            low = f.lower()
            if is_incomplete_marker(f):
                partial.append(p)
            if RARANY.search(f):
                rars.append(p)
                if PARTVOL.search(f):
                    if PARTONE.search(f):
                        mains.append(p)
                elif low.endswith(".rar") or re.search(r'\.001$', f):
                    mains.append(p)
            elif low.endswith(VIDEXT) and not re.search(r'sample', p, re.I):
                vids.append(p)
    return sorted(mains), rars, vids, partial


# ---------------------------------------------------------------- safety gates

def qb_paths():
    """Every path any live torrent references, translated to host paths."""
    import http.cookiejar
    cj = http.cookiejar.CookieJar()
    op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
    op.open(urllib.request.Request(
        "http://localhost:8080/api/v2/auth/login",
        data=urllib.parse.urlencode({"username": "admin",
                                     "password": "adminadmin"}).encode(),
        headers={"Referer": "http://localhost:8080"}), timeout=60)

    def api(p):
        return json.load(op.open("http://localhost:8080/api/v2" + p, timeout=300))

    def host(p):
        return "/storage/" + p[len("/media/"):] if p.startswith("/media/") else p

    paths = set()
    for t in api("/torrents/info"):
        sp = host(t["save_path"])
        paths.add(os.path.normpath(sp))
        if t.get("content_path"):
            paths.add(os.path.normpath(host(t["content_path"])))
        for f in api("/torrents/files?hash=" + t["hash"]):
            paths.add(os.path.normpath(os.path.join(sp, f["name"])))
    return paths


# ---------------------------------------------------------------------- phases

def process(lib, name, phases, commit, seeding, log, allow_extracted=False):
    base = LIBS[lib]
    folder = os.path.join(base, name)
    mains, rars, vids, partial = find_sets(folder)
    rep = {"lib": lib, "folder": name, "sets": [], "skipped": None,
           "parts": len(rars), "bytes": sum(os.path.getsize(p) for p in rars)}

    if not rars:
        rep["skipped"] = "no rar parts"
        return rep
    if vids and not allow_extracted:
        # Default: only act on folders with no video, i.e. genuinely unextracted.
        # --allow-extracted is the cleanup pass for folders that already
        # extracted but still hold their parts; the gates below still apply, so
        # a set is only retired once its own output is present and byte-exact.
        rep["skipped"] = "already has %d video file(s)" % len(vids)
        return rep

    for main in mains:
        s = {"main": os.path.relpath(main, folder), "gates": {}, "outputs": []}
        vols = volumes_of(main)
        s["volumes"] = len(vols)
        expect, rc = listing(main)
        s["gates"]["listable"] = (rc == 0 and bool(expect))
        if not s["gates"]["listable"]:
            s["result"] = "UNREADABLE"
            rep["sets"].append(s)
            continue

        dest = os.path.dirname(main)

        # ---- verify: full CRC over every volume
        if "verify" in phases:
            t = unrar(["t", cpath(main)])
            s["gates"]["crc"] = (t.returncode == 0 and "All OK" in t.stdout)
            if not s["gates"]["crc"]:
                s["result"] = "CRC FAILED"
                s["error"] = (t.stdout + t.stderr).strip().splitlines()[-3:]
                rep["sets"].append(s)
                continue

        # ---- extract: -o- never overwrites an existing file
        if "extract" in phases:
            if commit:
                x = unrar(["x", "-o-", "-idq", cpath(main), cpath(dest) + "/"],
                          as_uid=owner_of(dest))
                s["gates"]["extract_rc0"] = (x.returncode == 0)
                if x.returncode != 0:
                    s["result"] = "EXTRACT FAILED"
                    s["error"] = (x.stdout + x.stderr).strip().splitlines()[-3:]
                    rep["sets"].append(s)
                    continue
            else:
                s["gates"]["extract_rc0"] = None  # dry run

        # ---- confirm every claimed output exists at its exact byte size
        ok_sizes = True
        for fn, sz in expect:
            p = os.path.join(dest, fn)
            actual = os.path.getsize(p) if os.path.exists(p) else None
            s["outputs"].append({"name": fn, "expect": sz, "actual": actual})
            if actual != sz:
                ok_sizes = False
        s["gates"]["sizes_match"] = ok_sizes

        # ---- gates that must hold at the moment of the move, not earlier
        s["gates"]["no_hardlink"] = all(os.stat(p).st_nlink == 1 for p in vols)
        hits = [p for p in vols if os.path.normpath(p) in seeding]
        s["gates"]["not_seeding"] = not hits
        s["gates"]["no_incomplete_marker"] = not partial
        if hits:
            s["seeding_hits"] = hits[:5]

        if "trash" in phases:
            gates = s["gates"]
            # `no_incomplete_marker` is intentionally NOT required. It is a proxy
            # for "the archive set may be truncated", and a passing `unrar t`
            # plus byte-exact output is direct proof that it is not. The markers
            # that tripped it in practice were stale ~uTorrentPartFile*.dat left
            # by unrelated aborted downloads in the same folder; all 28 sets it
            # blocked had verified clean and extracted byte-exact. It stays in
            # the report because it is worth seeing, just not worth blocking on.
            need = ["listable", "crc", "sizes_match", "no_hardlink", "not_seeding"]
            # Only demand a successful extract when this invocation actually ran
            # one. An earlier version required `extract_rc0` unconditionally, so a
            # `--phases verify,trash` cleanup pass could never retire anything --
            # the key is simply absent, reads as falsy, and every set was kept with
            # an empty reason. `sizes_match` already proves the output is present
            # and byte-exact regardless of which run produced it.
            if "extract" in phases and commit:
                need.append("extract_rc0")
            if all(gates.get(g) for g in need):
                if commit:
                    for p in vols:
                        rel = os.path.relpath(p, base)
                        tp = os.path.join(base, TRASH, rel)
                        os.makedirs(os.path.dirname(tp), exist_ok=True)
                        log.write("MOVE\t%s\t%s\n" % (p, tp))
                        log.flush()
                        shutil.move(p, tp)
                    s["result"] = "TRASHED %d parts" % len(vols)
                else:
                    s["result"] = "WOULD TRASH %d parts" % len(vols)
            else:
                s["result"] = "KEPT (gate failed: %s)" % ",".join(
                    g for g in need if not gates.get(g))
        else:
            s["result"] = "extracted" if commit else "dry-run"
        rep["sets"].append(s)
    return rep


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lib", choices=list(LIBS), action="append")
    ap.add_argument("--folder", action="append",
                    help="folder name; repeatable. omit for every rar-only folder")
    ap.add_argument("--phases", default="verify,extract,trash")
    ap.add_argument("--commit", action="store_true",
                    help="actually extract and move. without it, nothing is written")
    ap.add_argument("--allow-extracted", action="store_true",
                    help="also visit folders that already hold a video, to retire "
                         "parts left behind by an earlier run")
    ap.add_argument("--log", default="/storage/movies/.rar-trash/reclaim.log")
    a = ap.parse_args()

    phases = set(a.phases.split(","))
    libs = a.lib or list(LIBS)
    seeding = qb_paths()
    print("live torrent paths: %d" % len(seeding), file=sys.stderr)

    targets = []
    for lib in libs:
        base = LIBS[lib]
        names = a.folder if a.folder else sorted(os.listdir(base))
        for n in names:
            fp = os.path.join(base, n)
            if n in SKIP_DIRS or not os.path.isdir(fp):
                continue
            mains, rars, vids, _ = find_sets(fp)
            if rars and (not vids or a.allow_extracted):
                targets.append((lib, n))
    print("targets: %d" % len(targets), file=sys.stderr)

    if a.commit:
        os.makedirs(os.path.dirname(a.log), exist_ok=True)
    log = open(a.log, "a") if a.commit else open(os.devnull, "w")
    reports = []
    for lib, n in targets:
        print("  -> %s/%s" % (lib, n), file=sys.stderr)
        reports.append(process(lib, n, phases, a.commit, seeding, log,
                               allow_extracted=a.allow_extracted))
    log.close()
    print(json.dumps(reports))


if __name__ == "__main__":
    main()
