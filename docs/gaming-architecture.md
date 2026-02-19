# Cloud Gaming Architecture

## Runtime Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              User with Moonlight                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      │ Connects to VM's Sunshine
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Gaming VM (suspended)                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐ │
│  │ Sunshine                                                                 │ │
│  │  └── session-start.sh hook                                              │ │
│  │       └── Writes to /mnt/gaming/session-state/hostname.session          │ │
│  └─────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      │ NFS
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         NAS: /tank/gaming/session-state/                     │
│                              hostname.session (JSON)                         │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      │ inotifywait
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Proxmox Host: session-watcher.sh                          │
│                                                                              │
│  1. Detects session file change                                              │
│  2. Looks up VMID from /etc/gpu-manager/vm-map.json                         │
│  3. Calls: qm resume <vmid>  (if suspended)                                  │
│  4. VM wakes up, Sunshine accepts connection                                 │
│                                                                              │
│  On session end:                                                             │
│  1. Detects status: "inactive" in session file                              │
│  2. Schedules suspend after grace period (default: 5 minutes)               │
│  3. Calls: qm suspend <vmid> --todisk                                        │
└─────────────────────────────────────────────────────────────────────────────┘
```

## GPU Profile Strategy

### Why Multiple VMs Instead of Dynamic Profiles

NVIDIA vGPU mdev profiles are assigned at VM creation time. Changing profiles requires:
1. Shutting down the VM completely
2. Modifying the Proxmox VM configuration
3. Starting the VM again

This takes 1-2 minutes and loses any running state. Instead, we use **multiple pre-configured VMs**:

| VM Name | Profile | VRAM | Use Case |
|---------|---------|------|----------|
| linux-gaming-1 | Q-8C | 8GB | Standard AAA games |
| linux-gaming-2 | Q-8C | 8GB | Second player slot |
| linux-power | Q-24C | 24GB | Demanding games (Cyberpunk, etc.) |
| windows-gaming | Q-8C | 8GB | Windows-exclusive games |

### How Users Select Profiles

In Moonlight, each VM appears as a separate "PC":
- **Gaming-1** (Q-8C) - Your everyday gaming VM
- **Gaming-2** (Q-8C) - For a second player
- **Power-Gaming** (Q-24C) - When you need the full GPU

Users simply connect to the appropriate VM based on their game's requirements.

### Automatic Profile Hints (Future)

A potential enhancement: game-profiles.json maps games to recommended profiles:
```json
{
  "steam:1245620": {"name": "Elden Ring", "profile": "Q-8C"},
  "steam:1091500": {"name": "Cyberpunk 2077", "profile": "Q-24C"}
}
```

Moonlight could show a recommendation, but the user still picks the VM.

## VM Lifecycle States

```
                    ┌──────────────────┐
                    │     Created      │
                    │   (never run)    │
                    └────────┬─────────┘
                             │ first boot
                             ▼
    ┌────────────────────────────────────────────────────────┐
    │                                                         │
    │                      ┌──────────────┐                   │
    │     session end      │   Suspended  │  session start    │
    │   ┌──────────────────│  (to disk)   │◄──────────────┐   │
    │   │                  └──────────────┘               │   │
    │   │                         ▲                       │   │
    │   │                         │ suspend               │   │
    │   │                         │                       │   │
    │   ▼                         │                       │   │
    │ ┌───────────────────────────┴───────────────────────┐   │
    │ │                    Running                         │   │
    │ │              (Sunshine accepting)                  │   │
    │ └───────────────────────────────────────────────────┘   │
    │                                                         │
    └────────────────────────────────────────────────────────┘
                      Normal operation cycle
```

### Suspend vs Shutdown

We use **suspend-to-disk** (`qm suspend --todisk`) instead of shutdown because:
- Faster resume (~10-15 seconds vs 30-60 seconds boot)
- All applications stay open
- Game state preserved (if paused)
- GPU memory contents saved

The tradeoff is disk space (VM RAM size saved to disk).

## Preemption (Background Tasks)

The GPU manager tracks which VMs are using GPU resources:

```bash
# Check current state
gpu-allocate.sh status

# Example output:
{
  "total_vram": 24576,
  "used_vram": 16384,
  "available_vram": 8192,
  "active_sessions": ["linux-gaming-1"],
  "allocations": {
    "101": {"profile": "Q-8C", "priority": "game"},
    "102": {"profile": "Q-8C", "priority": "background"}
  }
}
```

When a user wants Q-24C but only 8GB is free:
1. Check for VMs with `priority: background` and no active session
2. Gracefully shutdown background VM
3. User can now start the Q-24C VM

Background tasks (LLM inference, transcoding) should be tagged with `priority: background`.

## Network/Discovery

### Sunshine/Moonlight Pairing

Each VM runs its own Sunshine instance. Options for pairing:

**Option A: Pair each VM individually**
- Simple but requires pairing each device to each VM

**Option B: Shared credentials via NFS**
1. Designate one VM as "pairing master"
2. Pair all Moonlight clients to that VM
3. Export `/home/gamer/.config/sunshine/` to NFS
4. Other VMs mount this read-only

Currently implemented: Option B via `/mnt/sunshine-creds` mount.

### VM Discovery

Moonlight discovers Sunshine instances via mDNS/Bonjour. Each VM should have a unique hostname that appears in Moonlight's PC list.

## Storage Architecture

```
Workstation (local NVMe)           NAS (NFS)
┌─────────────────────────┐       ┌─────────────────────────────┐
│ ZFS pool: games         │       │ ZFS pool: tank/gaming       │
│                         │       │                             │
│ games/vms/              │       │ emulation/roms/     (ro)    │
│   linux-gaming-1        │       │ emulation/users/    (rw)    │
│   linux-gaming-2        │       │ cloud-saves/        (rw)    │
│   windows-gaming        │       │ sunshine-credentials (ro)   │
│                         │       │ session-state/      (rw)    │
│ games/steam/ (optional) │       │ games/steam/        (rw)    │
└─────────────────────────┘       └─────────────────────────────┘
```

- **VM disks**: Local ZFS for performance, enables instant snapshots
- **Game libraries**: Can be local (faster) or NFS (shared across VMs)
- **Saves**: NFS for backup and sharing
- **Session state**: NFS so host can monitor VM sessions
