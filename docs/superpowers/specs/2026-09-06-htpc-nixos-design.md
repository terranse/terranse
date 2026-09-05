# HTPC on NixOS: declared capabilities, gated auto-deploy, remote access

Date: 2026-09-06
Status: approved, not yet implemented

## Context

The HTPC is a bare-metal 13th-gen Intel i3 box whose job is to run
[home-player](../../../../home-player) — a FastAPI backend, a Leptos/WASM web
UI, and a Tauri kiosk shell on the TV. home-player is now an internal Nix
flake exporting `nixosModules.default` (the backend as a system service) and
`homeModules.default` (the kiosk as a graphical-session service).

Three things are wanted from it:

1. Its capabilities are **declared**, the way `configurations.tfvars` declares
   what every other machine in the fleet runs.
2. A push to home-player **reaches the TV on its own**, without defeating the
   guarantees that made NixOS the right choice.
3. It is **remotely reachable** automatically, like every other
   terranse-managed host.

## Goals

- One overview of what the machine runs, in the spirit of `configurations.tfvars`.
- A push to home-player master reaches the box with no human step, gated on CI.
- The box never interrupts playback to update itself.
- A bad revision cannot leave the TV broken overnight.
- `ssh htpc.edholm.cc` works, and the access layer is thin enough to hand over
  to `ipid` later without unpicking anything.

## Non-goals

Specified here, built elsewhere or later:

- home-player's `/system/activity` endpoint and the update popup UI. This spec
  fixes the **contract**; the implementation is home-player's.
- TV power control (the box has no CEC — see Decisions). Home Assistant
  already has an entry for the TV and is the intended route.
- RF/BT remote pairing and wake-from-remote.
- `ipid`-based access and trust. Deliberately not pre-built.
- Netbird enrolment. LAN DNS plus SSH is sufficient until ipid lands.

## Decisions

| Decision | Rationale |
|---|---|
| The machine runs **NixOS** | home-player is already a flake with a NixOS module; the box is greenfield. |
| terranse owns the declaration | The user's homelab IaC is the single place machines are declared. |
| **tfvars declares identity; Nix declares configuration** | tfvars answers "what machines exist and how do I reach them"; Nix answers "what does this machine do". tfvars never described the inside of an LXC either — `docker_services` names a bundle whose contents live elsewhere. |
| A thin **role registry**, not a role system | NixOS modules already *are* roles. The registry is a name→path index and nothing more; configuration stays in typed options with assertions. Building a schema on top of the module system would reimplement it badly. |
| terranse and home-player both move to **gitlab.com** (private) | The build must happen on the LAN to reach the box. The gitlab-runner LXC polls outward, so it works from behind NAT; GitHub-hosted runners cannot reach the LAN at all. A self-hosted GitHub runner is free but costs a new docker template, a new role, and a second CI dialect for no capability gain. |
| **Pull-capable, push-preferred** delivery | The box may be asleep or off. CI pushes when WoL lands and the box fetches on boot when it did not. A sleeping TV must never turn a pipeline red. |
| CI **signs**; it does not activate | CI ships bytes and writes a pointer. The box verifies signatures and decides when to switch. A stolen deploy key uploads bytes the box refuses, rather than granting root. |
| Binary cache is a **ZFS dataset served over static HTTP** | `nix copy --to file://` produces a valid cache. No Nix, and no daemon, on the serving host. |
| Secrets are **1Password references**, checked in | Values never enter the repo, the Nix store, or CI. Injection runs from the laptop, where `op` is already unlocked, so no service-account token needs to exist on the LAN. |
| No CEC role | The box is a 13th-gen i3 with no CEC support. `home-player`'s `withCec` override also does not build offline. |

### On "auto-update defeats the purpose of NixOS"

It would, if the box accepted *an update*. It does not. It accepts one
specific store path, signed by a key it already trusts, pinned by a
`flake.lock` bump that a green pipeline made, recorded as a generation it can
roll back from, and activated by its own root-owned policy at a moment it
chose. Every system that ever ran corresponds to a terranse commit that can be
checked out and rebuilt. That is a stronger guarantee than `apt upgrade`, not
a weaker one.

## Architecture

Four components, each with one job.

### 1. `terranse/flake.nix` + `terranse/nix/` — the configuration

```
terranse/
  flake.nix                       # inputs: nixpkgs, home-manager, home-player
                                  # outputs: nixosConfigurations.*, checks
  nix/
    machines.nix                  # the single pane: machine -> roles
    roles/base.nix                # always applied, never listed
    roles/video.nix
    roles/home-player.nix
    roles/kiosk.nix
    roles/staged-updates.nix
    hosts/htpc/hardware-configuration.nix
    hosts/htpc/secrets.env.tpl    # op:// references, no values
  scripts/ship.sh                 # build, sign, publish, wake, push
```

The flake is at the repo root rather than under `nix/`, so deploy URLs carry
no `?dir=` subtlety.

### 2. `configurations.tfvars` — the identity

```hcl
htpc = {
  ansible_host = "htpc.edholm.cc"
  ansible_user = "default-user"
  kind         = "nixos"
  mac          = "aa:bb:cc:dd:ee:ff"   # the NIC's MAC, filled at install; the DHCP
                                       # reservation and the CI WoL step read this one declaration
  # Roles are declared in nix/machines.nix — this side owns identity only.
}
```

`variable "hosts"` is `type = any`, and every `lxcs`/`vms`/`host_roles` lookup
is `try()`-guarded, so this entry needs no module-contract changes. It gets a
DHCP reservation (hence `htpc.edholm.cc` via dnsmasq registration) and an
inventory entry. `host_roles` stays empty, so the generated playbook contains
no plays for it.

### 3. home-player on gitlab.com

Builds and tests itself; on green, triggers terranse's pipeline.

### 4. The binary cache

A ZFS dataset at `/srv/nix-cache`, published over static HTTP. Written by
`nix copy --to file://`, read by the box when a push did not land.

## The role registry

Each role owns the namespace `roles.<name>.*`. Presence in a machine's list
sets `enable = true`; `settings` are spliced into that namespace.

```nix
# nix/machines.nix
{
  htpc = {
    system = "x86_64-linux";
    roles = [
      { name = "video";          settings = { driver = "intel"; }; }
      { name = "home-player";    settings = { web.enable = true; }; }
      { name = "kiosk"; }
      { name = "staged-updates"; }
    ];
  };
}
```

`{ name, settings }` mirrors tfvars' `roles = [{ name, vars }]` deliberately.

```nix
# flake.nix (excerpt)
mkMachine = hostname: { system, roles }:
  nixpkgs.lib.nixosSystem {
    inherit system;
    specialArgs = { inherit inputs hostname; };
    modules = [
      ./nix/hosts/${hostname}/hardware-configuration.nix
      roleModules.base
      { networking.hostName = hostname; }
    ]
    ++ map (r: roleModules.${r.name}) roles
    ++ map (r: { roles.${r.name} = { enable = true; } // (r.settings or {}); }) roles;
  };
```

An unknown role name must fail with a message naming the offender and listing
the valid roles — the courtesy `tofu/modules/validation` already gives for
missing Ansible roles — rather than a bare "attribute missing".

Composition is declarative: two roles touching the same option merge, and a
genuine conflict fails at evaluation time, before anything is built.

### The roles

- **`base`** (implicit, never listed): `default-user` with the ed25519 key and
  passwordless `wheel` sudo (matching how the LXCs accept `become: true`, so
  root login stays disabled); sshd key-only; DHCP and hostname so
  `htpc.edholm.cc` registers itself; flakes enabled; the builder's public
  signing key in `trusted-public-keys`; the `deploy` user and its single sudo
  entry; `nix.gc` weekly with `--delete-older-than 30d`.
- **`video`** — `driver` is an enum. `intel` selects `intel-media-driver` plus
  `vpl-gpu-rt`, sets `LIBVA_DRIVER_NAME=iHD`, and enables pipewire with HDMI
  audio.
- **`home-player`** — imports the flake's `nixosModules.default`; sets
  `environmentFile = "/var/lib/home-player-secrets/env"`, deliberately without
  a `-` prefix so a missing secrets file fails the unit loudly instead of
  running it with no API keys. Also sets
  `services.home-player.wakeOnLan.enable`, so the box re-arms WoL at every
  boot and CI can wake it.

  Two traps in this role specifically. The `environmentFile` value must be a
  **quoted string**, not a bare Nix path: a bare `/var/lib/...` is copied into
  the store at evaluation time, which both leaks the intent and fails on a
  builder where the file does not exist. And `web.enable` serves the built
  bundle over nginx for **local or tunnelled debugging only** — the flake's own
  documentation notes the bundle has `http://127.0.0.1:9600` compiled in, so a
  browser on another device calls its own loopback and is refused. It is not a
  remote-access feature.
- **`kiosk`** — greetd autologin into `cage` running `home-player-shell`, via
  home-manager's NixOS module consuming the flake's `homeModules.default`.
- **`staged-updates`** — the receiver and activation policy, below.

## Secrets

`nix/hosts/htpc/secrets.env.tpl` is checked in and is literally an `op inject`
template:

```
JELLYFIN_API_KEY=op://Homelab/jellyfin/api_key
SONARR_API_KEY=op://Homelab/sonarr/api_key
RADARR_API_KEY=op://Homelab/radarr/api_key
```

`just secrets htpc` runs `op inject` on the laptop and pipes the result over
SSH into `/var/lib/home-player-secrets/env` (0600 root:root), then restarts
the backend. It is idempotent, so re-running it is the entire rotation
procedure — which is the only time it is expected to run.

Ansible was considered and rejected for this. Its advantage is idempotence
across a fleet, which does not apply to one file on one host, and it would
require `python3` on an otherwise minimal NixOS box purely to place it. The
template is kept per-host (`nix/hosts/<host>/secrets.env.tpl`) so that
promoting this to a generic Ansible play, if a second Nix machine appears, is
mechanical.

## Delivery pipeline

On push to home-player master:

1. `nix flake check` and `nix build .#backend .#web .#shell`. The runner is
   the existing gitlab-runner LXC on a `nixos/nix` image with a **persistent
   `/nix` docker volume** — without it, every pipeline rebuilds Rust and WASM
   from zero.
2. Green ⇒ multi-project `trigger:` into terranse's pipeline.
3. terranse's deploy job, in **one job** so the lock bump cannot re-trigger CI
   (the commit also carries `[skip ci]`), with a `resource_group` so
   simultaneous pushes serialise:
   - `nix flake update home-player` (the current form; `nix flake lock
     --update-input` is deprecated) and commit the bump. This
     commit is the gate made concrete.
   - `nix build .#nixosConfigurations.htpc.config.system.build.toplevel`
   - `nix store sign --recursive` with the builder key.
   - `nix copy --to file:///srv/nix-cache`, then write the store path to
     `/srv/nix-cache/pointers/htpc`.
   - `wakeonlan $MAC`, poll SSH for ~90s. Reachable ⇒ `nix copy --to
     ssh-ng://deploy@htpc` and stage. Unreachable ⇒ **the job still succeeds**;
     cache and pointer are the durable artifact.

A push to terranse itself (a role change) flows through the identical path and
gate. `just deploy htpc` is the laptop-side entry point, calling the same
`scripts/ship.sh`, so there is one implementation with two entry points.

The runner must be visible to both projects: registered at group level over a
group containing both, or added as a project runner to each.

## Activation policy on the box

State:

- `/nix/var/nix/gcroots/htpc-pending` → the staged system. A GC root, so
  automatic collection cannot eat it.
- `/var/lib/htpc-update/state.json` → what the home screen reads.

`deploy` gets exactly one passwordless sudo entry, `htpc-stage <path>`, whose
first action is `nix store verify --recursive` against the trusted keys. Trust
is enforced on the box, by the box.

`htpc-update.service` (root, oneshot; also on a 15-minute timer):

1. Pending equals current → exit.
2. Compare pending and running kernel/initrd → decide `switch`, or `boot`
   followed by a deferred reboot.
3. `GET 127.0.0.1:9600/system/activity` → `{"busy": bool}`.
   - **idle** → activate now.
   - **busy** → change nothing; write `state.json` so the home screen can offer
     the popup. The timer re-checks, so the update also lands on its own the
     moment playback ends, whether or not the popup is ever accepted.
4. Activate: `nix-env -p /nix/var/nix/profiles/system --set <pending>` — this
   creates the generation, and therefore the rollback — then
   `switch-to-configuration switch`.
5. Watchdog: poll the backend for 120s. No healthy response ⇒ `--rollback`,
   switch back, log loudly, and append the store path to
   `/var/lib/htpc-update/bad-revisions`, which the policy engine consults in
   step 1 — so the timer does not rollback-loop on it every fifteen minutes.
   A later, different revision is unaffected; only that exact path is barred.
6. On boot, before the policy engine: read the HTTP pointer, `nix copy --from`
   the cache if it differs, stage. Nobody is watching at boot, so it activates
   immediately. This is the path that catches every push where WoL did not
   land.

### Popup contract (home-player's side)

- The backend reads `state.json`: the pending revision, why it is pending, and
  whether a reboot is required.
- The UI offers "Update ready — apply now?".
- Accepting triggers `htpc-update-apply.service` through a **polkit rule scoped
  to that single unit**. The backend gets no sudo and no shell; it can request
  exactly one pre-declared action.

## Bootstrap runbook

Ordering matters — two steps are chicken-and-egg.

1. Install NixOS from the minimal ISO; hostname `htpc`, DHCP.
2. Generate `hardware-configuration.nix` on the box, copy it into
   `nix/hosts/htpc/`, commit.
3. Generate the builder signing keypair
   (`nix-store --generate-binary-cache-key`). The **public** half is committed
   and baked into `roles/base` as a trusted key; the private half goes to
   1Password and then into a masked GitLab CI variable. Same for the deploy SSH
   keypair: public in `base`, private as a CI variable.
4. `just deploy htpc` from the laptop. This first generation **must already
   carry** the trusted key and the deploy user, or CI's first push is refused
   by the box — correct behaviour, but confusing if hit by accident.
5. `just secrets htpc`.
6. Enable WoL in the BIOS. The `home-player` role arms it on the wired
   interface at boot via `services.home-player.wakeOnLan.enable`, which the
   flake's NixOS module already provides.
7. Add the tfvars `htpc` entry and `tofu apply`. This writes only the DHCP
   reservation; no container work.

## Failure modes

| Failure | Outcome |
|---|---|
| WoL does not land | Pipeline stays green; the box pulls from the cache on next boot |
| Push dies mid-copy | Harmless — the pending pointer moves only after `nix store verify` succeeds |
| Bad revision passes CI | Watchdog rolls back, marks it bad, stops retrying |
| Kernel update | Staged as `boot`; the reboot waits for idle |
| gitlab.com unreachable | The box keeps running its current generation; updates pause |
| Two pushes race | `resource_group` on the deploy job serialises the lock bumps |
| Secrets missing | The backend unit fails loudly rather than running with no API keys |
| Disk pressure on the box | Weekly `nix.gc` with a 30-day horizon; `ship.sh` checks free space before copying |

Three known weaknesses, recorded rather than hidden:

- **The watchdog is only as good as the health signal.** If `/health` returns
  200 while the UI renders blank, rollback will not fire. Requiring the kiosk
  user unit to be active as well narrows this, but does not close it.
- **A box that is never idle never reboots.** A pending kernel update could sit
  indefinitely. `state.json` carries its age so it is at least visible; an
  escalation policy is deliberately deferred rather than guessed at now.
- **The `file://` cache needs pruning.** `nix store gc` does not apply to it,
  so it grows without a small retention script keeping the last N pointers.

## Testing

- A **`nixosTest` VM for the activation policy** is the highest-value test in
  the design: boot a VM, stage a second generation, and assert that busy means
  nothing happens, idle means it activates, and an unhealthy backend means it
  rolls back *and* marks the revision bad. It runs in CI with no hardware and
  covers the logic most likely to ruin an evening.
- `nix flake check` in terranse evaluates every machine's
  `config.system.build.toplevel`, so a broken role fails the pipeline instead
  of the TV.
- A registry test: an unknown role name produces the helpful error, not a bare
  attribute-missing.
- `switch-to-configuration dry-activate` against the real box before the first
  live switch.

## Implementation order

The design is larger than one sitting, and the phases have a natural
dependency order. Each ends somewhere usable, so work can stop between them.

1. **A machine that boots and is reachable.** `flake.nix`, the role registry,
   `base`, `video`, `hardware-configuration.nix`, the tfvars entry. Deployed by
   hand with `nixos-rebuild --target-host`. Ends with `ssh htpc.edholm.cc`
   working and DNS registering itself.
2. **home-player running on it.** The `home-player` and `kiosk` roles, the
   secrets template and `just secrets htpc`. Ends with the TV showing the
   kiosk after a cold boot.
3. **The pipeline.** Both repos onto gitlab.com, the runner's persistent `/nix`
   volume, the cache dataset, signing keys, `scripts/ship.sh`, and
   `just deploy htpc`. Ends with a push building and publishing a signed
   closure — still activated by hand.
4. **The activation policy.** `staged-updates`, the boot-time fetch, the
   watchdog, and the `nixosTest`. Ends with the whole loop closed.
5. **The popup**, in home-player: the `/system/activity` endpoint, the
   `state.json` reader, and the polkit-scoped apply trigger.

Phase 4 is where the `nixosTest` earns its cost, and phase 3 is the one most
likely to expose surprises — private `git+ssh` flake inputs need an SSH key and
`known_hosts` inside the runner's container, which is easy to get wrong and
easy to test early.
