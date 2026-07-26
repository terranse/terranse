#!/usr/bin/env python3
"""Re-dump live media-stack state and rewrite the audit checklists.

Existing marks are preserved, keyed on folder name, so ticking entries off
survives a refresh. See README.md.
"""
import json
import os
import re
import subprocess
import sys

HOST = "media.edholm.cc"
OUT = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(OUT, ".cache")

# Remote collectors. The media host has python3 but no curl and no jq, and its
# login shell is fish -- so everything goes over `ssh <host> python3 -`.
DUMP_ARR = r'''
import json, urllib.request
SK = "271ab53c333c4aa49a8748fe13d32782"
RK = "752c6b177a934e938636cac8ae29e013"
def get(port, key, path):
    r = urllib.request.Request("http://localhost:%d%s" % (port, path),
                               headers={"X-Api-Key": key})
    return json.load(urllib.request.urlopen(r, timeout=180))
out = {}
out['sonarr_root'] = get(8989, SK, "/api/v3/rootfolder")
out['radarr_root'] = get(7878, RK, "/api/v3/rootfolder")
out['series'] = [
    {k: s.get(k) for k in ('id','title','year','path','rootFolderPath','tvdbId','imdbId','monitored','status')}
    | {'files': s.get('statistics',{}).get('episodeFileCount'),
       'eps': s.get('statistics',{}).get('totalEpisodeCount'),
       'size': s.get('statistics',{}).get('sizeOnDisk')}
    for s in get(8989, SK, "/api/v3/series")]
out['movies'] = [
    {k: m.get(k) for k in ('id','title','year','path','rootFolderPath','tmdbId','imdbId','monitored','hasFile')}
    for m in get(7878, RK, "/api/v3/movie")]
print(json.dumps(out))
'''

DUMP_JF = r'''
import json, urllib.request
K = "0357ed0dc0d94373ab0bc4c832d11b96"
def call(path):
    r = urllib.request.Request("http://localhost:8096" + path, headers={"X-Emby-Token": K})
    return json.load(urllib.request.urlopen(r, timeout=300))
q = ("/Items?Recursive=true&IncludeItemTypes=%s"
     "&Fields=Path,ProviderIds,ProductionYear&EnableTotalRecordCount=true&limit=5000")
out = {'folders': [{k: f.get(k) for k in ('Name','CollectionType','ItemId','Locations')}
                   for f in call("/Library/VirtualFolders")]}
for t in ('Series', 'Movie', 'Video'):
    out[t] = [{'Id': i['Id'], 'Name': i.get('Name'), 'Year': i.get('ProductionYear'),
               'Path': i.get('Path'), 'Prov': i.get('ProviderIds', {})}
              for i in call(q % t)['Items']]
print(json.dumps(out))
'''

DUMP_DISK = r'''
import os, re, json
VID = ('.mkv','.mp4','.avi','.m4v','.mov','.wmv','.mpg','.mpeg','.ts','.iso',
       '.vob','.img','.divx','.flv','.m2ts','.rmvb','.ogm')
RAR = re.compile(r'\.(rar|r\d\d|00\d)$', re.I)
SKIP = ('.torrents', 'System Volume Information')
out = {}
for key, base in (('tv','/storage/tv_series'), ('movies','/storage/movies')):
    ents = []
    for n in sorted(os.listdir(base)):
        fp = os.path.join(base, n)
        if n in SKIP or not os.path.isdir(fp):
            continue
        nvid = size = nfo = nrar = rarsize = 0
        partial = False
        for root, dirs, files in os.walk(fp):
            for f in files:
                low = f.lower()
                full = os.path.join(root, f)
                # a release's sample clip is not the movie
                if low.endswith(VID) and not re.search(r'sample', full, re.I):
                    nvid += 1
                    try:
                        size += os.path.getsize(full)
                    except OSError:
                        pass
                elif RAR.search(f):
                    nrar += 1
                    try:
                        rarsize += os.path.getsize(full)
                    except OSError:
                        pass
                elif low.endswith('.nfo'):
                    nfo += 1
                if 'uTorrentPartFile' in f or f.endswith('.!qB'):
                    partial = True
        ents.append({'name': n, 'nvid': nvid, 'size': size, 'nfo': nfo,
                     'nrar': nrar, 'rarsize': rarsize, 'partial': partial})
    out[key] = ents
print(json.dumps(out))
'''


def remote(script):
    return json.loads(subprocess.run(
        ["ssh", HOST, "python3", "-"], input=script,
        capture_output=True, text=True, check=True).stdout)


def basename(p):
    return os.path.basename((p or "").rstrip("/"))


def human(n):
    for unit in ("B", "K", "M", "G", "T"):
        if n < 1024:
            return "%.0f%s" % (n, unit)
        n /= 1024
    return "%.1fP" % n


def load_marks(path):
    """Existing checkbox state, keyed on the backticked folder name.

    Only `x` is read back, and it only survives on entries whose sole remaining
    flag is `soft` -- a human having reviewed an expected oddity and blessed it.
    A tick never survives a hard defect: an earlier run ticked `Marvels Daredevil`
    while miscounting its sample clips as episodes, and that stale tick then hid
    41 GB of unextracted RAR. A tick recorded before a defect was known is not
    evidence about that defect.
    """
    marks = {}
    if os.path.exists(path):
        for line in open(path):
            m = re.match(r"^- \[(.)\] `([^`]+)`", line)
            if m and m.group(1) == "x":
                marks[m.group(2)] = "x"
    return marks


def build(kind, arr, jf, dk):
    if kind == "tv":
        disk, app, jitems = dk["tv"], arr["series"], jf["Series"]
        prefix, good, appname, idkey = "/media/tvshows/", "/media/tv_series", "sonarr", "tvdbId"
    else:
        disk, app, jitems = dk["movies"], arr["movies"], jf["Movie"]
        prefix, good, appname, idkey = "/media/movies/", "/media/movies", "radarr", "tmdbId"

    by_folder = {}
    for a in app:
        by_folder.setdefault(basename(a["path"]), []).append(a)
    by_jf = {}
    for i in jitems:
        p = i["Path"] or ""
        key = p.split(prefix, 1)[1].split("/")[0] if p.startswith(prefix) else "??"
        by_jf.setdefault(key, []).append(i)

    rows = []
    for d in disk:
        name, note = d["name"], []
        # hard  = machine-verifiable defect. Never inherits a previous tick, because
        #         a tick recorded before the defect was known is not evidence.
        # soft  = expected-but-worth-a-look (a pack folder the *arr cannot represent).
        #         A human tick sticks on these.
        hard = soft = False
        A, J = by_folder.get(name, []), by_jf.get(name, [])

        if not A:
            app_flag = "MISSING"
            note.append("not in %s" % appname)
            # several films in one directory is a pack -- Radarr binds one movie per
            # folder, so it structurally cannot track these. Jellyfin handles them.
            if len(J) > 1:
                soft = True
            else:
                hard = True
        elif len(A) > 1:
            app_flag = "DUP x%d" % len(A)
            note.append("%d %s entries share this folder" % (len(A), appname))
            hard = True
        else:
            a = A[0]
            stale = not a["path"].startswith(good + "/")
            app_flag = "id=%d%s" % (a["id"], " STALE-PATH" if stale else "")
            if stale:
                note.append("path `%s`" % a["path"])
            note.append('%s="%s (%s)" %s=%s'
                        % (appname, a["title"], a.get("year"), idkey[:-2], a.get(idkey)))
            if kind == "tv" and not a["files"]:
                note.append("**0 files in sonarr**")
                hard = True
            if kind == "movies" and not a["hasFile"]:
                note.append("**no file in radarr**")
                hard = True
            if stale:
                hard = True

        if not J:
            jf_flag = "MISSING"
            note.append("not in jellyfin")
            hard = True
        elif len(J) > 1:
            jf_flag = "x%d" % len(J)
            note.append("jellyfin has %d items here (pack folder?)" % len(J))
            soft = True
        else:
            j = J[0]
            jf_flag = "ok"
            note.append('jellyfin="%s (%s)" tmdb=%s tvdb=%s'
                        % (j["Name"], j["Year"], j["Prov"].get("Tmdb"), j["Prov"].get("Tvdb")))
            if len(A) == 1:
                a = A[0]
                mine, theirs = ("tvdbId", "Tvdb") if kind == "tv" else ("tmdbId", "Tmdb")
                if a.get(mine) and j["Prov"].get(theirs) and str(a[mine]) != str(j["Prov"][theirs]):
                    note.append("**ID MISMATCH** %s %s=%s vs jellyfin %s=%s"
                                % (appname, theirs.lower(), a[mine], theirs.lower(), j["Prov"][theirs]))
                    hard = True

        if not d["nvid"]:
            if d.get("nrar"):
                note.append("**UNEXTRACTED RAR** — %d parts, %s%s"
                            % (d["nrar"], human(d["rarsize"]),
                               ", incomplete download" if d.get("partial") else ""))
            else:
                note.append("**EMPTY on disk**")
            hard = True

        rows.append({"name": name, "hard": hard, "soft": soft, "app": app_flag, "jf": jf_flag,
                     "disk": "%d vid %s" % (d["nvid"], human(d["size"])),
                     "note": "; ".join(note)})

    on_disk = {d["name"] for d in disk}
    orphans = [a for a in app if basename(a["path"]) not in on_disk]
    return rows, orphans


def write(kind, fname, title, root, arr, jf, disk):
    rows, orphans = build(kind, arr, jf, disk)
    path = os.path.join(OUT, fname)
    marks = load_marks(path)

    def mark_for(r):
        if r["hard"]:
            return "/"                       # evidence of a defect always wins
        if not r["soft"]:
            return "x"                       # verifies clean in all three
        return "x" if marks.get(r["name"]) == "x" else "/"

    for r in rows:
        r["mark"] = mark_for(r)
    flagged = sum(1 for r in rows if r["mark"] == "/")

    L = ["# %s audit" % title, "",
         "One entry per folder under `%s`. See [README](README.md) for the marker "
         "legend and workflow." % root, "",
         "- `[ ]` not yet verified &nbsp; `[x]` verified correct in all three "
         "&nbsp; `[/]` **needs your eyes**", "",
         "**%d folders — %d verified clean, %d flagged for review.**"
         % (len(rows), len(rows) - flagged, flagged), "",
         "## Library", ""]
    for r in rows:
        L.append("- [%s] `%s` — %s | jf:%s | %s"
                 % (r["mark"], r["name"], r["app"], r["jf"], r["disk"]))
        if r["note"]:
            L.append("  <sub>%s</sub>" % r["note"])
    if orphans:
        L += ["", "## Tracked but no folder on disk", "",
              "Entries that exist in %s with no matching directory. Not part of the "
              "count above." % ("Sonarr" if kind == "tv" else "Radarr"), ""]
        for a in sorted(orphans, key=lambda x: x["title"]):
            mark = marks.get("!" + a["title"], "/")
            L.append("- [%s] `!%s` — id=%d path=`%s`" % (mark, a["title"], a["id"], a["path"]))

    open(path, "w").write("\n".join(L) + "\n")
    print("%-14s %4d rows, %3d flagged, %d orphans" % (fname, len(rows), flagged, len(orphans)))


def main():
    os.makedirs(CACHE, exist_ok=True)
    if "--cached" in sys.argv:
        data = {n: json.load(open(os.path.join(CACHE, n + ".json")))
                for n in ("arr", "jf", "disk")}
    else:
        data = {}
        for name, script in (("arr", DUMP_ARR), ("jf", DUMP_JF), ("disk", DUMP_DISK)):
            print("dumping %s..." % name, file=sys.stderr)
            data[name] = remote(script)
            json.dump(data[name], open(os.path.join(CACHE, name + ".json"), "w"))

    write("tv", "tv-series.md", "TV Series", "/storage/tv_series", **data)
    write("movies", "movies.md", "Movies", "/storage/movies", **data)


if __name__ == "__main__":
    main()
