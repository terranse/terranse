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
structurally cannot track a pack. Jellyfin does find the individual films inside them, but frequently
**identifies them wrongly** — see the pack-folder section below.

Split multi-part rips (`CD1`/`CD2` — *Cinderella Man*, *Mrs Doubtfire*, *Its Complicated*,
*Tusen Gånger Starkare*) show as fileless in Radarr and as two items in Jellyfin. They play fine; stacking
them properly would need a rename.

## Known outstanding

- **Extract the 471 GB of archives** and remove the parts once verified (see above — nothing is seeding
  from these folders).
- **Flatten the pack folders** so Jellyfin and Radarr can both see the individual films.
- **Delete the corrupt episode NFOs** on the ten affected series.
- **Re-identify the ~10 mis-matched Sonarr series** (needs a human — see above).
- **10 phantom `Video` items in Jellyfin** pointing into the deleted `Avatar - The Last Airbender[720p]`
  folder, half of them under the pre-migration `/media/tv_series/` prefix. The files are gone, so they are
  pure orphans. Removing them needs a `DELETE /Items/{id}` per item or a library scan.
- **`Pan(2015)[720p]` has no movie** — only a subtitle archive. Needs re-downloading.
- **3 Sonarr entries with no folder**: `Andor`, `Taskmaster`, `Avatar: The Last Airbender (2024)`.
  Two Radarr entries likewise (`Cloudy with a Chance of Meatballs`, `Sagan Om(2003)[DVD]`).
- **Duplicate collections** from mixed-language metadata: `Harry Potter (samling)` alongside
  `Harry Potter Collection`, same for `Kung Fu Panda`. Two collections hold a single film
  (`Cloudy with a Chance of Meatballs`, `Planes`).

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

**55 folders hold `.rar`/`.r00` part sets and no video file — 471 GB.** 50 movies (366 GB) and 5 series
(105 GB, of which `Heroes` alone is 2121 parts / 31 GB and `Marvels Daredevil` 895 parts / 44 GB). 236
archive sets in total, 183 of which contain a video. These are invisible to Jellyfin and fileless in
Sonarr/Radarr, which is what most of the remaining flags actually are. unpackerr is running but never
processed them — it watches the download client's queue, and these left the queue long ago.

**They are safe to extract and the archives are safe to remove afterwards.** Cross-checked against all 320
torrents in qBittorrent (`admin:adminadmin` on `:8080`; the stored PBKDF2 hash is the well-known default):
every torrent seeds from a `.torrents` subdirectory, **none** from the library folders holding these
archives, and **no RAR part has `nlink > 1`**, so no hardlink elsewhere depends on them either. These
predate the current download-into-`.torrents`-then-hardlink workflow.

8 of the 55 carry incomplete-download markers (`~uTorrentPartFile*`, `.!qB`) and must be treated as suspect
until an integrity check passes.

### A folder with *some* video can still be mostly archived

`unrar_reclaim.py` skips any folder that already contains a video, on the reasoning
that it was never archived. That is right for movies — one folder, one film — and
badly wrong for series, where extracted and still-archived episodes sit side by side.

It hid **~320 GB**: Game of Thrones had 12 extracted episodes and **61 archived
sets** (84.7 GB), Agents of SHIELD 32 against 51 sets, Big Bang Theory 129 against
98. Every one was quietly skipped as "already has N video file(s)".

`--allow-extracted` visits them anyway. Note it only helps if the run *includes*
the extract phase — a `--phases verify,trash` pass over these correctly refuses
every set on `sizes_match`, because there is no extracted output to compare
against yet, which reads deceptively like "leftovers I declined to remove".

To tell the two cases apart, check whether each directory that holds a RAR set also
holds a video. All of them → genuine leftovers. None → still archived.

### Use the qBittorrent container's unrar, never the host's

`/usr/bin/unrar` on the host is **`unrar-free` 0.3.1, which silently corrupts this job**: it cannot follow a
multi-volume set. On a 522 MB / 11-volume archive it wrote only the first 50 MB volume, printed
`Truncated RAR file data` and `Failed` — **and still exited 0**. A naive `unrar x && rm *.rar` would have
destroyed the archives after a failed extraction.

The **qbittorrent container has real `UNRAR 7.20` and `7z 26.00`**, and already mounts `/storage` at
`/media`. It spans volumes correctly, and `unrar t` does a full CRC check with a truthful exit code:

```bash
docker exec qbittorrent unrar t "/media/movies/<folder>/<name>.rar"   # verify (reads every volume)
docker exec qbittorrent unrar x -o- "/media/movies/<folder>/<name>.rar" "/media/movies/<folder>/"
```

Three folders do not yield a normal video file: `Law Abiding Citizen(2009)[DVD]` contains `wk-repack.lac.img`
and `The Da Vinci Code(2006)[DVD]` contains `dv-innsyn.iso` (both DVD images), while `Pan(2015)[720p]` holds
**only a subtitle archive** — the movie's own RAR set is absent, so that title is simply missing.

A release's `Sample/` clip is not the feature — the disk scan excludes any path matching `sample`, which is
what exposed `Heroes` as 80 sample clips rather than 80 episodes, and `Marvels Daredevil` as having no video
at all.

## Pack folders break Jellyfin's movie matching

Where several films live in subfolders under one library-level folder, Jellyfin mis-assigns their identities
— and not randomly, but **rotated**, which makes it look plausible at a glance:

| Folder on disk | Jellyfin thinks it is |
|---|---|
| `…/Star Wars Episode IV A New Hope(1977)` | Episode I – The Phantom Menace |
| `…/Star Wars Episode I The Phantom Menace(1999)` | Episode II – Attack of the Clones |
| `…/Star Wars Episode II Attack Of The Clones(2002)` | Episode III – Revenge of the Sith |
| `…/Star Wars Episode III Revenge Of The Sith(2005)` | The Empire Strikes Back |
| `…/Star Wars Episode V The Empire Strikes Back(1980)` | Return of the Jedi |
| `…/Star Wars Episode VI Return Of The Jedi(1983)` | Star Wars (1977) |

All six wrong. `Harry Potter Collection[1080p]` is shifted by one the same way; `Terminator Trilogy[1080p]`
has T1, T2 and T3 all identified as *Terminator Salvation* (a film not even present);
`The Lord of the Rings Trilogy[1080p]` has *The Two Towers* labelled *The Return of the King*.
`Resident Evil Collection[720p]` and `Underworld Trilogy[720p]` happen to be correct.

Jellyfin expects `movies/<Title (Year)>/<file>`. A nested pack folder violates that, and Radarr cannot track
one either — it binds a single movie per folder. **Flattening each film's subfolder up to the top level of
`/storage/movies` fixes both at once.** `flatten_packs.py` moved 28 films; Star Wars (all 6) and LOTR (all 3)
corrected themselves on the next scan.

Two did not: `Terminator 2` and `Terminator 3` kept the stale *Terminator Salvation* identity through the
move, because **Radarr had written per-file `.nfo` sidecars** naming Salvation — Radarr had the whole pack
registered as that one film, and a local NFO beats `RemoteSearch/Apply`. Removing those sidecars and setting
the identity through `POST /Items/{id}` fixed both. A sweep of all per-file movie NFOs whose title disagrees
with their folder found 19, of which only these two were genuinely wrong; the other 17 are Swedish folder
names against English metadata titles (`Flickan Som Lekte Med Elden` → *The Girl Who Played with Fire*),
which is correct.

> **`/Items?Recursive=true` serves stale data.** After fixing the Terminator pair, that endpoint kept
> reporting the old identity for more than ten minutes while `GET /Users/{uid}/Items/{id}` already showed the
> corrected values. Verify a single item by ID; do not trust the list endpoint to confirm a write landed. Collections themselves work fine (90 box sets, correctly populated);
their membership is only wrong where the underlying film is misidentified. Note `/Items?ParentId=<boxset>`
returns 0 without `Recursive=true` — that is a query artifact, not an empty collection.

## Corrupt NFOs are widespread, and Jellyfin is following them

`LocalMetadataReaderOrder: ["Nfo"]` means a bad NFO beats correct filenames. Ten series are affected, and
Jellyfin's episode numbering matches the corruption exactly:

| Series | NFOs claim | Jellyfin shows |
|---|---|---|
| `Band Of Brothers [720p]` | all 10 → `S20E01` | 10 episodes in season 20 |
| `Planet Dinosaur(2011)[720p]` | all 6 → `S20E11` | 6 episodes in season 20 |
| `Pixar Short Film Collection [1080p]` | `S20E13`, `S19E…` | seasons 19 and 20 |
| `BBC Planet Earth II` | all 6 → season 1, no episode | 6 episodes with no index |
| `Spartacus Blood and Sand(2010)` | all 6 → season 1, no episode | 6 episodes with no index |
| `Walking with Dinosaurs - Swedish(1999)` | all 7 → season 1, no episode | 7 episodes with no index |
| `Star Wars - The Clone Wars` | 117 NFOs, season but no episode | **63 of 117** with no index |
| `Breaking bad` | 27 → `S00E02`, 16 → `S05E05`, 13 → `S03E03` | duplicate index in S1, extras scrambled |
| `Dinosauriernas Planet (2011)` | no season *or* episode tag | season `null`, no index |
| `Krigets Unga Hjärtan` | no season *or* episode tag | season `null`, no index |

Season 20 and 19 are not typos in this table — the NFO writer emitted them.

Deleting the corrupt NFOs — the obvious repair — would have made it worse. These releases predate `SxxExx`
naming: the files are `Part06.avi`, `…3of6.Jungles…`, `Planet.Dinosaur.III…`, `…Del.3.av.3…`, and Jellyfin's
fallback parser gets no episode number from any of them. `fix_nfo.py` instead maps each series' own naming
scheme to a real season/episode and rewrites the NFOs. 190 written, 289 moved to `.nfo-trash/`.

Breaking Bad is the exception: its episode files are `Season 3 Episode 11 - Abiquiu.avi`, which parses
natively, so only its 99 cloned `Extras/` NFOs were removed.

### An NFO cannot override Jellyfin's season parse

Applying the NFOs needs `POST /Items/{id}/Refresh?metadataRefreshMode=FullRefresh&replaceAllMetadata=true`.
With `replaceAllMetadata=false` Jellyfin only fills *gaps*, so a wrong-but-present season survives untouched.

More importantly, **Jellyfin takes season and episode from the filename in preference to the NFO**, and it
reads a bare four-digit year as `SxxExx`:

| Filename | Jellyfin reads | Truth |
|---|---|---|
| `Planet.Dinosaur.III.2011.720p…` | `2011` → S20E11 | S01E03 |
| `luxo.jr.1986.1080p…` | `1986` → S19E86 | S01E02 |
| `Band.Of.Brothers.2001.E03…` | `E03` wins → S01E03 | S01E03 ✓ |
| `…Walking with Beasts (3-6) - Land of Giants.avi` | `(3-6)` → S03E03 | S03E03 ✗ season right by luck, wrong pattern |

This is almost certainly where the corrupt NFOs came from in the first place — some tool wrote them out of
exactly this misparse, which is why Band of Brothers' NFOs said `S20E01` (`2001`) and Planet Dinosaur's said
`S20E11` (`2011`).

The NFO title and episode number *are* honoured; only the season is overridden. Where the filename contains
no season-like token the rewritten NFO applies cleanly — that fixed 8 of the 10 series. Three groups needed
the ambiguity removed from the filename instead, which `rename_episodes.py` did for 25 files. Moving them
into a real `Season 01/` folder does **not** help; the filename parse still wins.

All ten are correct now:

| Series | Before | After |
|---|---|---|
| `Band Of Brothers` | 10 episodes collapsed into one, "season 20" | S01E01–E10, real titles |
| `Star Wars - The Clone Wars` | 63 of 117 with no episode number | 22/19/22/21/20/13 across S1–S6, 0 unindexed |
| `Breaking bad` | extras scrambled, duplicate index in S1 | 7/13/13/13/16 |
| `Planet Dinosaur` | all 6 in "season 20" | S01E01–E06 — and Jellyfin then pulled real TVDB titles |
| `Walking with…` | 19 episodes spread over 6 seasons | 3/6/6/4 — Monsters, Dinosaurs, Beasts, Cavemen |
| `Pixar Short Film Collection` | seasons 19 and 20 | 13 shorts at S01E01–E13 |
| `BBC Planet Earth II` | 6 episodes with no index | S01E01–E06 |
| `Spartacus Blood and Sand` | 6 with no index | S00E01–E06 (the folder holds *Gods of the Arena*) |
| `Dinosauriernas Planet` | season `null` | S01E01–E03 |
| `Krigets Unga Hjärtan` | season `null` | S01E01–E03 |

One deliberate residue: three Despicable Me minions shorts are misfiled under `Pixar Short Film Collection`
and still sit in a phantom "season 20". They are Illumination's, not Pixar's, so both `fix_nfo.py` and
`rename_episodes.py` skip them by name rather than stamping the wrong show onto them. They want moving out
of the TV library altogether.

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
