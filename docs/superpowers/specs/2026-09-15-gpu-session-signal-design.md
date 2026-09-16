# Design: give gpu-manager a session signal it can actually read

**Date:** 2026-09-15
**Repos:** `terranse` (guest + host Ansible), `gpu-manager` (the daemon),
`computer-configs` (the `gpu` fish function, which renders the new fields)
**Depends on:** the default tenant (`default_tenant`, already implemented) —
this spec supplies the *trigger* that hands a card back; the default tenant is
what picks it up.

## The problem

`gpu-manager` is configured to release an idle gaming VM after
`grace_period_s: 300`, freeing the card. That timer has never fired once,
because the signal it depends on does not exist. Verified on the live host:

```
$ gpu-manager ctl status
vm ai-vm        stopped  session=unknown sunshine=false
vm gaming       running  session=unknown sunshine=false
```

Three independent breaks, each sufficient on its own:

1. **The directory is nowhere.** `session_dir` is `/mnt/gaming/session-state`.
   On the Proxmox host that path does not exist at all. In the gaming guest it
   exists but is an empty *local* directory — the NFS mount declared in
   `ansible/roles/gaming/tasks/game-storage.yaml:131` never happened, and the
   guest now carries only virtiofs mounts (`nvidia-guest-drivers`,
   `gaming-pc-games`, `gaming-emulation`). The share the design assumed was
   retired when game storage moved to virtiofs; the session contract was not
   moved with it.
2. **The names do not match.** The daemon stats `<session_dir>/<vm-name>`
   (`activity.Scan`). The hook writes `<session_dir>/$(hostname).session`
   (`sunshine-session-start.sh.j2`). Even correctly mounted, they never meet.
3. **Ending a session leaves the marker in place.** The stop hook rewrites the
   file with `status: "inactive"` and only removes it if `jq` fails. The daemon
   tests existence, not content, so a finished session would read as live
   forever.

Because every session reads `unknown`, and `unknown` is deliberately never
treated as idle, `PlanSteps` skips its release step on every pass
(`planner.go` step 6 requires `!UnknownSession[vm] && IdleFor >= grace`). The
card is held until a human intervenes.

## Approach: the guest reports over HTTP; the shared directory goes away

Rather than repair a shared-filesystem contract between a host daemon and its
guest — three bugs of which two were *contract* bugs, not mount bugs — the
guest tells the daemon directly. The daemon already runs an HTTP server, and
the guest can reach it. Verified:

```
gaming -> 192.168.1.200:8080 = HTTP 200
```

This deletes the whole bug class: no mount to exist, no filename convention to
agree on, no marker file whose content and existence can disagree.

### Considered and rejected

- **Put the markers on a virtiofs share** (mirroring the game libraries). Fixes
  break 1 with a pattern already proven in this repo, but keeps a file-based
  contract with two parties, and still needs breaks 2 and 3 fixed by hand. It
  preserves the thing that failed.
- **Poll Sunshine's own API from the host.** No guest-side hooks at all, and
  the daemon would read the source of truth. Rejected for now: it needs
  Sunshine's admin credentials on the Proxmox host (1Password item
  `Infrastructure/Sunshine Gaming`), and Sunshine's HTTPS API is not a
  documented stable surface for "is a client streaming". Worth revisiting if
  the hooks prove unreliable.

## Design

### Daemon: session reports replace directory scanning

Two new endpoints, shaped like the existing claim endpoints:

- `PUT /v1/sessions/{vm}` — a session is live on `{vm}`. Idempotent; this is
  also the heartbeat. Optional body `{"client": "..."}`, for display only.
- `DELETE /v1/sessions/{vm}` — the session ended.
- An unknown `{vm}` is `400`, as `PUT /v1/claims/{vm}` already is.

`activity.Activity` stops reading the filesystem and becomes API-fed:

| Transition | Resulting session state |
|---|---|
| `PUT` received | `active`, `lastSeen` = now |
| `DELETE` received | `idle`, `lastSeen` = now (starts the grace clock) |
| no report within `session_ttl_s` of an `active` | `unknown` |
| never reported (daemon start) | `unknown` |

The one invariant that must not move: **an expired heartbeat becomes `unknown`,
never `idle`.** A reporter going quiet does not tell us the session ended, and
treating it as idle would evict a live game. Only an explicit `DELETE` produces
`idle`, so only a clean session end starts the grace clock.

This is deliberately conservative, and it means the heartbeat does not itself
enable any eviction — a crashed reporter yields `unknown`, which is never
evicted, exactly like today's stale `active` would not be. What the heartbeat
buys is that the daemon stops *claiming* a session is live when it has not
heard from it in minutes: `unknown` is the honest answer, and it also stops a
stale `active` from blocking a non-preempting claim for another VM.

### Reading it back: no GET, but publish the clock

There is deliberately **no** `GET /v1/sessions/{vm}`. Session state already
rides in `GET /v1/state` — `observe()` fills `VMState.Session` from
`Act.State(name)`, and that is what `ctl status` prints today. A second read
path for the same fact would be one more thing to keep consistent.

What *is* missing is the elapsed time. `IdleFor` is computed on every pass and
then discarded: it never reaches the state document. So a status command can
say `session=idle` but not how far through the grace period that VM is — which
is the question anyone asks it once idle release actually works. Two fields
fix that:

- `VMState.idle_for_s` — seconds since the `DELETE` that made this VM idle.
  Omitted when the VM is not idle (it is meaningless for `active`, and for
  `unknown` reporting a duration would imply knowledge the daemon does not
  have).
- `Doc.grace_period_s` — the configured grace period, echoed once. Without it
  a client has to know the daemon's config to render the number usefully, and
  the state document is otherwise self-describing.

Together those let `ctl status` and the `gpu` fish function print
`session=idle 2m14s/5m`, i.e. when the card is about to come free. Both are
read-only additions to an existing response; no endpoint changes.

Config changes:

- Add `session_ttl_s`, default `180` (three 60 s heartbeats). Must not be
  negative.
- `session_dir` is no longer required and no longer read. `yaml.v3` ignores
  unknown keys, so the order of rollout does not matter: a new daemon tolerates
  a config that still carries `session_dir`, and the old required-field check
  goes away in the same change.

### Guest: Sunshine hooks call the API

`sunshine-session-start.sh.j2` and `-stop.sh.j2` become `curl` calls. Both must
stay non-fatal — they run as Sunshine `global_prep_cmd`, where a non-zero exit
aborts the stream — so every failure is logged and swallowed, and the scripts
still end in `exit 0`.

The hook plumbing itself already works and is left alone. Verified in the
guest: Sunshine runs as `gamer` under that user's `systemd --user`, and
`sunshine.conf:83` already wires both scripts:

```
global_prep_cmd = [{"do": "/opt/sunshine/hooks/session-start.sh",
                    "undo": "/opt/sunshine/hooks/session-stop.sh"}]
```

So this is a change of destination, not of mechanism — only the two scripts'
bodies change.

A `systemd --user` timer in `gamer`'s manager (the same one supervising
Sunshine) sends the heartbeat every 60 s. The start hook starts the timer, the
stop hook stops it, so nothing heartbeats outside a session and no separate
"is a session live" check is needed in the guest.

Two new role variables, both named rather than assumed:

- `gpu_manager_api_url` — where the daemon listens, as the *guest* can reach it
  (`http://192.168.1.200:8080`; the guest is on the LAN, not on netbird).
  Declared in the gaming VM's `roles[].vars` in
  `tofu/deployments/edholm/configurations.tfvars`, next to the other gaming
  role vars, and passed through `| mandatory` so a missing declaration fails at
  template time rather than silently producing hooks that report nowhere.
- `gpu_manager_vm_name` — the VM's name *as the daemon's config keys it*
  (`gaming`), defaulting to `ansible_hostname`. It is a contract with
  `config.yaml`'s `vms:` map, not an incidental hostname, so it gets a name.

### Remove what is now dead

- The NFS session-state mount tasks (`gaming/tasks/game-storage.yaml:25`,
  `:131-132`) and the fstab line in `cloud-init-gaming.yaml.j2:19`.
- The `session-state` export and directory in the `gaming-storage` role
  (`tasks/main.yaml:72`, `:122`, `templates/exports.j2:27`) — that role's other
  exports are untouched.
- `SESSION_STATE_DIR` in `gpu-manager/files/health-check.sh`, which currently
  reports a missing directory as a warning on every run.
- `gpu_manager_session_dir` from the role defaults and config template.

### Fix in the same subsystem: `host:` never reaches the daemon

The config template emits `host:` only `{% if vm.host is defined %}`, and
`local.gaming_vms_by_host` in `tofu/deployments/edholm/main.tf` builds
`{vmid, mounts, tier}` — never `host`. So `cfg.VMs[vm].Host` is always empty,
which means `sunshine_reachable` is permanently `false` and `StepWaitSunshine`
never runs on a handover: the daemon reports a claim satisfied the moment the
VM starts, before the stream is up. Carry `host` in the locals and the template
does the rest.

## The chain this completes

```
Sunshine session ends
  -> DELETE /v1/sessions/gaming     (stop hook)
  -> session=idle, grace clock starts
  -> 300s later: PlanSteps shuts the gaming VM down
  -> card free, and gaming was the last holder
  -> default tenant armed: ai-vm takes the card
```

## Testing

**gpu-manager**
- `activity`: a `PUT` makes a VM active; a `DELETE` makes it idle and starts
  `IdleFor`; an `active` VM past `session_ttl_s` becomes `unknown` and its
  `IdleFor` returns to zero; a never-reported VM is `unknown`.
- `server`: both endpoints on a known VM; `400` on an unknown one. `/v1/state`
  publishes `idle_for_s` for an idle VM, omits it for an active and an unknown
  one, and echoes `grace_period_s`.
- `reconcile`: a game reported idle past the grace period is shut down; one
  reported idle but *within* grace is not; an `unknown` one is never shut down
  regardless of elapsed time. Then the full chain — reported idle, past grace,
  shut down, default tenant takes the card in the following pass.

**terranse**
- Template tests for both hooks: they target `gpu_manager_api_url` and
  `gpu_manager_vm_name`, and a missing `gpu_manager_api_url` raises.
- The config template emits `host:` when `gaming_vms` carries one, and omits it
  otherwise.
- The config template no longer emits `session_dir`.

**computer-configs**
- No automated tests (the `gpu` function is verified by running it against the
  live daemon, as it was when first written). `ctl`'s `printDoc` and the fish
  function's `status` verb both gain the idle clock.

## Known gaps, deliberately not addressed

- **The session endpoints are unauthenticated**, like every other endpoint on
  this daemon. Any host on the LAN can report a session for any VM, which at
  worst pins the card to a VM (reporting `active` blocks nothing an operator
  cannot preempt) or frees it early (reporting `idle` starts a 300 s clock).
  Adding auth is a change to the whole API surface, not to this feature.
- **Claims remain in memory.** A daemon restart still forgets an explicit
  `ai-vm` claim and demotes it to default-tenant priority.
- **A preempted game loses its session.** Unchanged and unfixable on this
  hardware: Proxmox refuses `qm suspend --todisk` for a VM with a
  passed-through PCI device.
