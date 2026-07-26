# Media library audit

A sweep of the whole library to get every title correctly mapped across **Sonarr/Radarr → Jellyfin → disk**.

The trigger was Avatar: The Last Airbender, which turned out to have three unrelated faults stacked on it
(stale Sonarr path, a season-pack parsed as S01 only, and a Jellyfin match against the 2024 live-action
remake). Fixing it surfaced that the stale-path fault is library-wide.

## The checklists

| File | Scope | Verified | Flagged |
|---|---|---|---|
| [tv-series.md](tv-series.md) | 71 folders under `/storage/tv_series` | 56 | 15 |
| [movies.md](movies.md) | 841 folders under `/storage/movies` | 760 | 81 |

One line per folder on disk — disk is the authority, since a title can be missing from Sonarr/Radarr
*or* from Jellyfin and both are real defects. Entries tracked in Sonarr/Radarr with no folder on disk
are listed separately at the bottom of each file, prefixed `!`.

### Markers

| Mark | Meaning |
|---|---|
| `[ ]` | Not yet verified |
| `[x]` | Verified: correct in Sonarr/Radarr, Jellyfin, and on disk |
| `[/]` | **Needs your eyes** — I could not decide, please review |

`[/]` is deliberately liberal. Anything where the metadata title diverges from the folder name in a way
that could plausibly be either a Swedish/alternate title (fine) or a genuine mis-identification (not fine)
gets flagged rather than guessed at. Common causes: pack folders holding several films, alternate-language
titles, provider-ID disagreements between the *arr and Jellyfin, and empty folders.

The `<sub>` line under each entry carries the evidence — the app-side title and provider IDs, the Jellyfin
title and provider IDs, and the on-disk video count and size.

## What is currently flagged

**TV (15).** Ten are Sonarr mis-identifications from when the series were added — Jellyfin is right in nine
of them (`Heroes` is registered as *Heroes (Heldon Van Dee Zee)*, `Sherlock Holmes` as the 1954 series when
it is BBC *Sherlock*, `The Boys(2019)` as *Water Boys*, `Pixar Short Film Collection` as *British Transport
Films*, `Krigets Unga Hjärtan` as *Kalla Krigets Hemligheter* when Jellyfin correctly has *Generation War*).
The exception is `Star Wars - The Clone Wars`, where Sonarr has the 2008 series correctly and **Jellyfin**
has the 2003 microseries. Four more are the unextracted-RAR folders, and `Jane Eyre(2006)[DVD]` is a
VIDEO_TS rip Sonarr cannot import.

Re-identifying a monitored series is not a safe bulk operation — it changes what Sonarr considers missing
and can trigger auto-searches — so these are left for a human decision rather than fixed mechanically.

**Movies (81).** Identification is clean: **zero** TMDB mismatches across all 824 Jellyfin movies versus
Radarr. Every flag is structural.

| Cause | Count |
|---|---|
| Unextracted RAR set | 49 |
| Not tracked by Radarr | 26 |
| Several films in one folder (packs) | 11 |
| Empty directory | 1 (`Movies`) |

The untracked ones are mostly deliberate pack folders (`Harry Potter Collection`, `Star Wars Hexalogy`,
`The Lord of the Rings Trilogy`, `Underworld Trilogy`, `Resident Evil Collection`, `Asterix`, `Konserter`)
plus alternate-language duplicates of films Radarr already has. Radarr binds one movie per folder, so it
cannot track a pack — Jellyfin handles them correctly and finds the individual films. The one genuinely
broken pack is `Terminator Trilogy[1080p]`: it contains T1, T2 and T3, but Jellyfin labels all three
*Terminator Salvation* and Radarr has it registered as *Terminator Salvation* too.

Split multi-part rips (`CD1`/`CD2` — *Cinderella Man*, *Mrs Doubtfire*, *Its Complicated*,
*Tusen Gånger Starkare*) show as fileless in Radarr and as two items in Jellyfin. They play fine; stacking
them properly would need a rename.

## Known outstanding

- **10 phantom `Video` items in Jellyfin** pointing into the deleted `Avatar - The Last Airbender[720p]`
  folder, half of them under the pre-migration `/media/tv_series/` prefix. The files are gone, so they are
  pure orphans. Removing them needs a `DELETE /Items/{id}` per item or a library scan.
- **Corrupt NFOs beyond Avatar.** `Breaking bad` has 27 NFOs all declaring `S00E02 "Wedding Day"`, 16 at
  `S05E05` and 13 at `S03E03` — all inside `Extras/`, so its specials are scrambled in Jellyfin the same way
  Avatar's episodes were. `Dinosauriernas Planet`, `Krigets Unga Hjärtan` and
  `Walking with... Monsters, Dinosaurs, Beasts, Cavemen` have NFOs carrying raw release names and no
  `<season>` tag at all.
- **3 Sonarr entries with no folder**: `Andor`, `Taskmaster`, `Avatar: The Last Airbender (2024)`.
  Two Radarr entries likewise (`Cloudy with a Chance of Meatballs`, `Sagan Om(2003)[DVD]`).

## Regenerating

`docs/media-audit/refresh.py` re-dumps the live state and rewrites both checklists **preserving existing
marks** (keyed on the folder name), so ticking things off is not lost when the data is refreshed.

```bash
python3 docs/media-audit/refresh.py
```

## Environment notes

See the `project-media-stack` memory for the full set. The ones that bite when scripting this:

- Stack runs as Docker containers in Proxmox LXC **CT 106**, `ssh media.edholm.cc`.
- Remote login shell is **fish** — pipe scripts (`ssh media.edholm.cc bash -s < f.sh`), never inline bash.
- Host has `python3` but **no `curl`, no `jq`** — drive the APIs with `urllib`.
- `/storage/tv_series` is ZFS `Tank/windows_smb_series` with **no snapshots**. Deletions are irreversible.

### Container path mapping

| Host | Sonarr | Radarr | Jellyfin | qBittorrent |
|---|---|---|---|---|
| `/storage/tv_series` | `/media/tv_series` | — | `/media/tvshows` | `/media/tv_series` |
| `/storage/movies` | — | `/media/movies` | `/media/movies` | `/media/movies` |

## The stale-path fault

An older layout mounted `/storage/tv_series` at `/media` (and `/storage/movies` at `/media`). Both are now
mounted one level deeper. Series and movies added before that change still carry `/media/<folder>` paths,
which now resolve to the container root — so imports fail with `UnauthorizedAccessException` and the entry
reports zero files even though the media is on disk. Sonarr logged `episodeFileDeleted` for the whole
affected set on 2023-07-26, which dates the migration.

Affected at the start of this audit: **54 of 74** Sonarr series, **717 of 822** Radarr movies.
768 records were rewritten (3 skipped — their folders no longer exist), then both containers were
restarted and rescanned. Sonarr went from 56 zero-file series to 10; Radarr from 722 fileless movies to 55.

Fixing one entry:

1. `PUT /api/v3/series/{id}?moveFiles=false` (or `/api/v3/movie/{id}`) with `path` and `rootFolderPath` corrected.
   `moveFiles=false` is essential — the files are already in the right place, only the record is wrong.
2. **Restart the container.** Sonarr caches the series object in memory for tracked downloads; `RefreshSeries`
   and `RescanSeries` are *not* enough on their own and imports keep failing against the old path.
3. `RescanSeries` / `RescanMovie` per entry to re-attach the files on disk.

## The unextracted-archive fault

**54 folders hold `.rar`/`.r00` part sets and no video file — 467 GB.** 49 movies (361 GB) and 5 series
(105 GB, of which `Heroes` alone is 2121 parts / 29 GB). These are invisible to Jellyfin and fileless in
Sonarr/Radarr, which is what most of the remaining flags actually are. unpackerr is running but never
processed them — it watches the download client's queue, and these left the queue long ago.

8 of the 54 carry incomplete-download markers (`~uTorrentPartFile*`, `.!qB`) so they will not extract
cleanly and need re-downloading instead.

`unrar` is present at `/usr/bin/unrar` on the host. Extracting in place roughly doubles the footprint of
each folder until the archives are deleted; `/storage/movies` had 3.4 TB free at time of writing.

A release's `Sample/` clip is not the feature — the disk scan excludes any path matching `sample`, which is
what exposed `Heroes` as 80 sample clips rather than 80 episodes.

## Fixing a mis-identified title in Jellyfin

Proven on Avatar. `POST /Items/RemoteSearch/Series` with an explicit `ProviderIds` block to find the right
candidate, then `POST /Items/RemoteSearch/Apply/{id}?replaceAllImages=true` with that candidate, then a full
metadata refresh. Poll afterwards rather than waiting on the call — both endpoints routinely outlive a
two-minute client timeout while succeeding server-side.

Two traps worth knowing:

- **Sonarr numbers season 0 by TVDB, Jellyfin by TMDB, and they disagree.** Where specials matter, pin them
  with per-episode `.nfo` files. The TV library has `LocalMetadataReaderOrder: ["Nfo"]`, so NFO wins.
- **`EnableInternetProviders: false` does not actually gate internet metadata fetching.** The per-type
  `MetadataFetchers` lists are the real switch.

Corrupt NFOs are worth ruling out early when sorting looks scrambled: the old Avatar folder had 61 `.nfo`
files that were all clones of episode 1, and because NFO beats filename parsing every episode reported as
S?E1 with the same title.
