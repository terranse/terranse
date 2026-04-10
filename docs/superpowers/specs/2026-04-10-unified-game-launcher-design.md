# Unified Game Launcher Design

## Problem

The gaming VM infrastructure supports Steam and RetroArch but lacks Epic Games Store, GOG, and other sources. There is no unified view of all games across stores. Each store requires navigating its own UI after connecting via Moonlight.

## Goal

A single-pane-of-glass experience where all games from all sources (Steam, Epic, GOG, RetroArch, Itch.io, etc.) appear in one controller-friendly launcher on the client device. Selecting a game launches it directly via Moonlight streaming (or locally for retro titles).

## Architecture

Three components across three repos:

```
Client Device                     Gaming VM (up to 3)              Workstation (Proxmox)
+-----------------------+         +-------------------------+      +---------------------+
| Game Launcher         |         | Lutris                  |      | GPU Manager          |
| (new repo #2)         |   HTTP  | - Steam/Epic/GOG/Retro  |      | - Dynamic vGPU       |
| - Unified game list   |-------->| - Install/launch/runners|      |   slice allocation   |
| - Controller UI       |         +------------+------------+      | - VM lifecycle (qm)  |
| - Moonlight launch    |         | Game Sync Service       |      | - Homogeneous A5000  |
| - Local retro option  |-------->| (new repo #1)           |      |   constraint         |
+-----------------------+         | - Lutris DB watcher     |      +---------------------+
                                  | - Sunshine apps.json gen|             ^
                                  | - Metadata + cover art  |             |
                                  | - Install/uninstall API |             |
                                  +------------+------------+      Client calls GPU mgr
                                  | Sunshine                |      before launching a
                                  | - One app entry per game|      Moonlight session
                                  | - KMS capture + stream  |
                                  +-------------------------+
```

### Repo boundaries

- **terranse** (this repo): Ansible roles to install Lutris, configure store integrations, deploy the sync service, extend GPU manager for dynamic slicing.
- **game-sync-service** (new repo #1): Python daemon bridging Lutris and Sunshine, plus metadata/install API for the client.
- **game-launcher** (new repo #2): Client-side controller-friendly UI. Separate design session.

## Component Details

### 1. Lutris on Gaming VMs (terranse)

Lutris acts as the unified game management layer. It already supports all target stores via built-in integrations and CLI backends.

**Store backends:**
- Steam: native Linux client (already installed), Lutris discovers its library
- Epic Games Store: via `legendary` CLI (Lutris's built-in Epic backend)
- GOG: via `gogdl` CLI (Lutris's built-in GOG backend)
- RetroArch: registered as a Lutris runner, ROM paths pointed at NFS mounts
- Itch.io and others: added via Lutris as needed

**Ansible tasks (new `lutris.yaml`):**
- Install Lutris via Flatpak (preferred for up-to-date version)
- Install runner dependencies: `legendary`, `gogdl`
- Fetch store credentials from 1Password via `op` CLI
- Configure store account authentication
- Register RetroArch as a Lutris runner with NFS ROM paths
- Trigger initial library import/sync from all connected stores

**Ansible tasks (new `game-sync.yaml`):**
- Install the game-sync-service package
- Configure: Lutris DB path, Sunshine apps.json path, metadata port, scan interval
- Deploy and enable systemd service
- Configure Sunshine to load apps from sync-managed path

**Changes to existing files:**
- `sunshine-apps.json.j2`: remove static app entries (Steam Big Picture, RetroArch, Terminal); these become dynamically generated. Keep only a "Desktop" fallback entry.
- `sunshine.yaml`: add dependency on game-sync service.
- `game-storage.yaml`: add NFS paths for cover art cache if shared across VMs.

**What stays the same:**
- Steam installation (Lutris discovers it, doesn't replace it)
- RetroArch installation (stays as-is, Lutris registers it)
- Sunshine core setup (config, hooks, streaming)
- NFS storage layout

### 2. Game Sync Service (new repo #1)

A lightweight Python service (FastAPI) running on each gaming VM. Bridges Lutris's game database with Sunshine's app list and serves metadata to the client launcher.

**Core responsibilities:**

1. **Library discovery**: Watch Lutris's SQLite DB (`~/.local/share/lutris/pga.db`) via inotify with 1-second debounce for local changes (installs, removals). Periodically trigger Lutris library resync and query store APIs directly (Steam Web API, `legendary list-games`, `gogdl list`) for full owned/shared libraries including uninstalled games and new purchases.
2. **Sunshine sync**: Generate Sunshine `apps.json` with one entry per installed game. Launch command per game: `lutris lutris:rungameid/<id>`.
3. **Metadata API**: Serve game catalog with rich metadata for the client launcher.
4. **Cover art**: Fetch and cache cover art from Steam CDN, SteamGridDB, IGDB, or Lutris's own cache.
5. **Install/uninstall API**: Allow the client to trigger game installation and report progress.

**Metadata schema:**

```json
{
  "vm_hostname": "gaming-01",
  "games": [
    {
      "id": "steam-12345",
      "name": "Half-Life 3",
      "source": "steam",
      "platform": "linux",
      "cover_url": "/covers/steam-12345.jpg",
      "state": "installed",
      "sunshine_app_name": "Half-Life 3",
      "gpu_profile_recommended": "Q-8C",
      "emulator": null,
      "family_shared": false
    },
    {
      "id": "epic-abcdef",
      "name": "Fortnite",
      "source": "epic",
      "platform": "windows",
      "cover_url": "/covers/epic-abcdef.jpg",
      "state": "not_installed",
      "sunshine_app_name": null,
      "gpu_profile_recommended": "Q-12C",
      "emulator": null,
      "family_shared": false
    },
    {
      "id": "retroarch-n64-mario",
      "name": "Super Mario 64",
      "source": "retroarch",
      "platform": "n64",
      "cover_url": "/covers/retroarch-n64-mario.jpg",
      "state": "installed",
      "sunshine_app_name": "Super Mario 64",
      "gpu_profile_recommended": null,
      "emulator": "mupen64plus",
      "family_shared": false
    }
  ]
}
```

**Game state values:** `installed`, `installing`, `not_installed`, `queued`, `update_available`

**Install/uninstall endpoints:**
- `POST /games/{id}/install` — triggers `lutris lutris:install/<slug>` or direct store CLI
- `POST /games/{id}/uninstall` — triggers removal via Lutris
- `GET /games/{id}/status` — returns install progress

**Family sharing:**
- Steam Family Sharing: shared games appear in Steam's library and Lutris should discover them. The `family_shared` field indicates whether a game comes from a family member's library. Availability depends on whether the owner is currently playing.
- Epic/GOG: no equivalent family sharing feature.

**Tech stack:**
- Python + FastAPI
- SQLite reads (Lutris DB) + inotify (`watchdog` library)
- Store API clients: Steam Web API, `legendary` CLI, `gogdl` CLI
- Cover art fetching: httpx + disk cache
- Packaged as systemd service, installed via uv/pip or .deb

### 3. GPU Manager Extension (terranse)

Extend the existing GPU manager on the workstation for dynamic vGPU slice reconfiguration.

**A5000 constraint:** all active vGPU slices must be equal size (homogeneous partitioning).

| Active sessions | Slice config | Per-VM VRAM |
|-----------------|-------------|-------------|
| 1               | 1x Q-24C   | 24 GB       |
| 2               | 2x Q-12C   | 12 GB       |
| 3               | 3x Q-8C    | 8 GB        |

**New behavior:**
- When a game launch is requested, evaluate: current active sessions, the new game's GPU requirements (from `gpu_profile_recommended` in game metadata), and the homogeneous constraint.
- Determine optimal slice configuration.
- If reconfiguration is needed (e.g., going from 1x Q-24C to 2x Q-12C): gracefully suspend the current session's VM, reconfigure all slices, resume VMs.
- Expose this as an API endpoint the client launcher calls before initiating a Moonlight session.
- The existing game profiles (`game-profiles.json.j2`) already map games to recommended GPU profiles; extend this to be consumed by the sync service.

### 4. Client Launcher (new repo #2)

Separate design session. Key interface requirements defined here for contract clarity:

**What the client does:**
- Queries each gaming VM's sync service metadata endpoint to build a unified, deduplicated game catalog
- Shows all games in a full-screen, controller-friendly UI (Big Picture style)
- Launches games via `moonlight stream <vm_host> --app "<sunshine_app_name>"`
- Before launching, calls the workstation's GPU manager to ensure correct slice configuration and VM is running
- For low-power retro platforms (N64, SNES, GBA, PSX, NES, Game Boy, etc.), offers option to launch RetroArch locally instead of streaming. Threshold configurable per console.
- Can trigger install/uninstall of games on VMs via the sync service API
- Shows install progress

**Multi-VM awareness:**
- Queries all gaming VMs' sync services
- Deduplicates games installed on multiple VMs
- Picks which VM to stream from: prefer already-running VM, then least-loaded
- If no VM is running, requests the workstation to start one with the right GPU slice

**What the client does NOT do:**
- Manage GPU slicing directly (delegates to GPU manager)
- Manage VM lifecycle directly (delegates to GPU manager / Proxmox)
- Manage game runners/prefixes (that's Lutris)

## Scope Summary

| Component | Repo | Effort | Notes |
|-----------|------|--------|-------|
| Lutris + store setup | terranse | Small | New Ansible task files |
| Sync service deploy | terranse | Small | Install + systemd config |
| GPU manager dynamic slicing | terranse | Medium | Extend existing allocation |
| Game sync service | new repo #1 | Medium | Python FastAPI service |
| Client launcher | new repo #2 | Large | Separate design session |

## Open Questions

1. **Steam Family Sharing discovery**: Verify that Lutris (or Steam's local library data) includes shared-but-uninstalled games from family members. If not, the sync service may need to query Steam's Web API directly.
2. **GPU profile database**: How to populate `gpu_profile_recommended` for games — manual curation, community database (PCGamingWiki?), or learned from usage patterns?
3. **Multi-VM game deduplication strategy**: If the same game is installed on multiple VMs, does the client always prefer a running VM, or should it consider other factors (save data location, installed mods)?
4. **Retro local-play threshold**: Which console generations are "safe" to run locally on typical client hardware? Propose: everything up to and including PS2/GameCube/Wii. Switch emulation streams from VM.
