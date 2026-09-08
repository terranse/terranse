# HTPC on NixOS — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Declare a bare-metal NixOS HTPC in terranse, get home-player's kiosk running on the TV, and close the loop so a push to home-player master reaches the box on its own — signed, gated on CI, activated only when nobody is watching, and rolled back if it breaks.

**Architecture:** A new `flake.nix` at the terranse repo root with a thin name→path role registry under `nix/`, and the box's disk declared with **disko** so the whole machine — and a matching installer ISO — build before the hardware is touched. `configurations.tfvars` gains an `htpc` identity entry (host, user, MAC) that feeds a DHCP reservation; Nix owns everything about what the machine *does*. Both repos move to gitlab.com so the existing on-LAN gitlab-runner LXC can build them; CI signs a closure into a ZFS-backed `file://` cache served over HTTP, wakes the box and pushes; a root-owned policy engine on the box verifies signatures, waits for idle, activates, and watchdogs the result.

**Tech Stack:** Nix flakes, NixOS modules, home-manager, disko, nixos-anywhere, `nixosTest`, OpenTofu (dnsmasq/Caddy via the opnsense provider), Ansible (docker role), GitLab CI, `just`, 1Password CLI.

**Spec:** `docs/superpowers/specs/2026-09-06-htpc-nixos-design.md`

## Open human gates and carry-forwards

Everything below is still open at the point this branch merges. It is recorded
here, in a tracked file, because the working ledger for this plan lives under
`.superpowers/sdd/`, which is gitignored and therefore does not merge -- this
section is the only record that travels with the code. Written for someone who
was not part of the original work.

**Nothing on this list is a bug.** Each item is either hardware that does not
exist yet, a credential only a human can create, or a deliberate temporary
setting. The code is written so that every one of them fails closed or does
nothing, rather than half-working.

### Must be done before the box's first install

- [ ] **`users.users.deploy` does not exist anywhere in `nix/`.** Task 1 is
      described as "generate the keypairs", but the account CI pushes to was
      never declared: `grep -rn deploy nix/` finds only
      `roles.staged-updates.deployUser`, which names an account that is not
      created. Both the `deploy` account (with the CI deploy key in
      `openssh.authorizedKeys.keys`) and the builder's public key (in
      `nix.settings.trusted-public-keys`) must go into `nix/roles/base.nix`
      before `nixos-anywhere` runs. If they are forgotten, CI's first push is
      simply refused and the fix is one more deploy -- but the box is then
      unreachable by CI until someone notices.
      Do **not** put `deploy` in `wheel`: `base.nix` grants wheel
      `NOPASSWD:SETENV: ALL`, which would make the single-command sudo rule in
      `nix/roles/staged-updates.nix` irrelevant and hand CI passwordless root.
- [ ] **`nix/hosts/htpc/disko.nix` still assumes `/dev/nvme0n1`.** Confirm
      against the real box (Task 3 Step 4) before writing anything.
- [ ] **Task 3 Steps 4-8** (write the USB stick, enable wake-on-LAN in the
      BIOS, run `nixos-anywhere`, post-install verification).

### Deliberate temporary settings that must be flipped

- [ ] **`roles.staged-updates.signingPublicKey` is `""`** (its default; nothing
      overrides it). While it is empty and `requireSignatures` is on,
      `htpc-stage` refuses **every** staged path outright -- by design, so the
      update path is genuinely inert rather than falling back to whatever the
      box already trusts. Set it, in `nix/machines.nix`, to the full
      `name:base64` line that `nix-store --generate-binary-cache-key` emitted
      in Task 1. The same key material also belongs in `base.nix`'s
      `trusted-public-keys`.
- [ ] **`roles.staged-updates.requireHealthy = false`** in `nix/machines.nix`.
      There is no `/health` to poll until home-player is deployed (Task 7/9),
      and `true` would roll back every good update and then permanently refuse
      it via `bad-revisions`. Flip it back -- or delete the override -- the
      moment home-player lands.
- [ ] **The placeholder MAC** in
      `tofu/deployments/edholm/configurations.tfvars` (`htpc.mac =
      "REPLACE-WITH-THE-MAC-FROM-TASK-3-STEP-5"`). `local.host_macs` in
      `main.tf` filters on a well-formed MAC, not on presence, so the
      placeholder produces no DHCP reservation and blocks no `tofu apply`.
      Replacing it with the real address is the whole of what turns the
      reservation on. Then run Task 5 Steps 7-10.
- [ ] **The `home-player` flake input does not exist yet.** Task 6 (create the
      gitlab.com projects) is human-gated, and Tasks 7 and 9 cannot evaluate
      without it. `scripts/ship.sh --bump` now asserts the input is present
      and refuses loudly rather than letting `nix flake update home-player`
      warn-and-exit-0 while the pipeline stays green -- so the `deploy-htpc`
      job fails until `flake.nix` gains the input. That is the gate working,
      not a regression.
- [ ] **`deploy-htpc` calls `ship.sh htpc` without `--bump`.** Restoring the
      flag is a one-line change to `.gitlab-ci.yml`, deliberately deferred
      rather than left to fail loudly: with no `home-player` input, the guard
      above would fail every run of this job from the moment the gitlab.com
      projects exist until Task 7 lands. Re-add `--bump` there the same time
      `flake.nix` gains the `home-player` input (Task 7's last step).

### Carry-forward into the kiosk work (Task 9)

- [ ] **`LIBVA_DRIVER_NAME` will not reach the kiosk.**
      `nix/roles/video.nix` sets `environment.sessionVariables.LIBVA_DRIVER_NAME
      = "iHD"`, which is written to `/etc/set-environment` -- a file a
      `systemd --user` unit does **not** source. The kiosk shell is a
      home-manager user unit, so the WebKitGTK process may never see `iHD` and
      will software-decode silently, with no error anywhere. Task 9 must
      propagate it explicitly: `Environment=` on the user unit, or
      `systemctl --user import-environment` /
      `dbus-update-activation-environment` in the session script. Verify with
      `vainfo` and by watching CPU during playback, not by reading config.

### CI prerequisites (Task 6)

- [ ] Project CI/CD variables on `gitlab.com/yarcod/terranse`, all masked:
      `DEPLOY_SSH_KEY` (base64 of the deploy private key), `KNOWN_HOSTS`
      (`ssh-keyscan` output), `CACHE_SIGNING_KEY` (the cache signing secret
      key), `CI_PUSH_TOKEN` (project access token, `write_repository`,
      Maintainer). The first three are now asserted with `:?` in
      `.gitlab-ci.yml`, so a missing or misnamed one fails immediately and
      says which.
- [ ] **The job-token allowlist**, not a trigger token. See Task 6 Step 8: an
      earlier draft of this plan told you to create a
      `TERRANSE_TRIGGER_TOKEN`, which would be dead configuration.
- [ ] **Task 10 Step 1** (the `nvmepool/nix-cache` dataset) and Steps 5-8;
      **Task 11 Step 3** (the group runner token into 1Password) and
      Steps 4-7; **Task 14 Steps 5-8** (deploy, prove the unsigned-path
      refusal, `state.json`, the boot-time fetch).
- [ ] **Tasks 6, 7, 8, 9 and 16** are human-gated in their entirety.

### Known, accepted, not defects

- **The `nix-store` volume is shared across the group runner.** The runner is
  registered at group level with one writable Nix store volume, so any job
  that can land on it could write a tampered store path a later `deploy-htpc`
  reuses and signs with the real builder key -- satisfying every check the box
  makes. The signature therefore proves "CI built this", which is only as
  strong as who can run a job on this runner. Ruled documentation-only: a
  dedicated project-scoped runner is a real change to a working shared runner.
  The assumption is stated at the volume declaration in
  `ansible/roles/docker/templates/gitlab-runner.yaml.j2`.
- **The `staged-updates` VM test does not run in CI.** `nix flake check` needs
  `/dev/kvm`, which the runner's LXC does not expose; the `flake-check` job
  skips that one check loudly. Run `nix flake check -L` on a machine with KVM
  before merging anything that touches `nix/roles/staged-updates.nix` -- that
  test is the only thing that exercises the activation policy end to end.
- **`just lint` is broken** for reasons predating this plan (`tests/static/` is
  empty). Use `just validate-tofu`, `just test-unit` and `nix flake check`.

## Global Constraints

- **The box is bare hardware with no OS today.** Because the disk layout is declared with **disko** rather than scanned off the machine, `nixosConfigurations.htpc` evaluates and builds on the laptop before the hardware is touched — so Tasks 1, 2 and 4 onwards need no box. Only Task 3 (the install) is hands-on.
- **`nix/profiles/` and the `kind` attribute already exist** — see the herdr plan, which landed the flake, the role registry, the shared `base` role and the metal/lxc profile split. `base.nix` is shared with containers and must stay free of bootloader and disk assumptions: a bootloader and nixpkgs' `proxmox-lxc` profile both define `system.build.installBootLoader`, which has no merge function, so a container importing a `base.nix` that set `boot.loader.*` fails to evaluate outright. Firmware and disk belong to `nix/profiles/metal.nix`; `system.stateVersion` belongs to `nix/hosts/<name>/default.nix`.
- **Tasks marked `(human)` are for Daniele to run.** They touch hardware, 1Password, gitlab.com accounts, or ZFS on the Proxmox hosts. Stop and hand over; do not improvise credentials or create remote projects.
- **Root filesystem is ZFS**, pool `rpool`, on a single disk, declared in `nix/hosts/htpc/disko.nix`. It matches the rest of the fleet and gives compression on a box that caches a lot of artwork. Two things ZFS demands and nothing else does: a `networking.hostId` (fixed at **`8f3a1c2d`**, used identically by the installer ISO and the installed system so imports are never forced) and a kernel ZFS actually builds against — leave `boot.kernelPackages` at the LTS default and let nixpkgs' own assertion catch a bad bump.
- **Installation is `nix build .#installer-iso` + `nixos-anywhere`.** Packer is deliberately not involved: this repo's Packer only builds Proxmox templates by SSHing to a node and driving `qm`, and has no bare-metal path. NixOS builds installer images natively from the same flake, so the installer and the installed system share one `flake.lock`.
- **The target disk is `/dev/nvme0n1`** in `disko.nix`. Task 3 Step 4 confirms this against the real box before anything is written; if it differs, that one line changes.
- **The ZFS dataset for the cache is created by Daniele**, not by this plan's automation (his explicit request). Task 10 gives him the exact commands and waits.
- Conventional commits, one topic per commit. Scopes in use and reusable here: `nix`, `tofu`, `docker`, `ansible`, `ci`, `docs`. Body explains *why*, ASCII `--` not em dashes, ~72 col wrap. End every commit message with:
  ```
  Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
  ```
- **Never commit** `terraform.tfstate*`, `tfplan`, `__pycache__`, or any secret value. `flake.lock` **is** committed.
- The generated `ansible/playbooks/edholm.yaml` and `ansible/inventory/edholm.yaml` are gitignored — never commit them.
- **`just lint` is already broken** (`tests/static/` is an empty directory, so `yamllint -c tests/static/.yamllint.yaml` fails). Do not use it as a gate and do not try to fix it here — out of scope. Use `just validate-tofu`, `just test-unit`, and `nix flake check`.
- **The gitlab.com namespace used throughout is `yarcod`**, i.e. `gitlab.com/yarcod/terranse` and `gitlab.com/yarcod/home-player`. If Daniele picks a different group in Task 6, substitute it in `flake.nix` (the `home-player` input URL), both `.gitlab-ci.yml` files, and `scripts/ship.sh`.
- **`system.stateVersion` is `"26.05"` for `htpc`**, declared in `nix/hosts/htpc/default.nix` and matched by the kiosk user's `home.stateVersion` in Task 9. It is per-machine, not fleet-wide — do not move it into `base.nix`. If the ISO built in Task 3 reports something else, use what `nixos-version` prints and change it in both places.
- The fleet SSH key, verbatim, is the one already in `tofu/deployments/edholm/defaults.tf:9-13`:
  `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEkdwh5G9JuqNpThbxYqP7RBT9CQJ1fkFeOGuP1sUrXK`
- **Reserved address for `htpc` is `192.168.1.51`** — the next free one after `vagrant-runner` at `.50`.

### Corrections to the spec, discovered during exploration

These are real and must be honoured; the spec is wrong or optimistic on each.

1. **The DHCP reservation is *not* free.** The spec (line 106-111) says the tfvars entry "needs no module-contract changes". The `opnsense-networking` *module* is indeed generic, but `tofu/deployments/edholm/main.tf:97-99,153-158` sources MACs **only** from `module.proxmox-lxc`, and `var.lxc_reserved_ips` is LXC-keyed. Task 5 adds the host-level plumbing.
2. **home-player's provider config key is `api_token`, not `api_key`.** `backend/home_player/providers/jellyfin.py:110` does `config["api_token"]`; the example in home-player's own `nix/modules/nixos.nix:72` writes `api_key` and would KeyError. Use `api_token`.
3. **The gitlab-runner is registered with `--executor shell`**, not docker (`ansible/roles/docker/tasks/additional/gitlab-runner.yaml:26`), despite the compose file's comment. Task 11 adds a *second* registration with the docker executor and the `nix` tag rather than changing the existing one.
4. **home-player has no git remote at all.** The move in Task 6 is "create and push", not "migrate".
5. **`tofu/modules/validation` is effectively a no-op** — it is instantiated with `var.configuration.roles` where `var.configuration` is a map of LXC names, so all three `try()`s yield `[]` and validation never fires. The Nix role registry is deliberately not modelled on it: the friendly unknown-role error is a real, tested function, already implemented and covered by `nix/tests/registry.nix` in the herdr plan. Task 2 Step 8 only confirms it fires for this machine.
6. **home-player's `nix/checks.nix:63-71` hard-asserts** that `services.home-player-shell` has exactly the option leaves `[ "backend" "enable" "extraEnvironment" "package" ]`. Nothing in this plan may rename them.
7. **`/system/activity` does not exist yet** (phase 5 of the spec, home-player's repo). Everything here must work with it absent: a failed request reads as *idle*.

---

## Task 1: Generate the signing and deploy keypairs **(human)**

**Files:** none in the repo yet — the public halves are pasted into `nix/roles/base.nix` in Task 2.

**Interfaces:**
- Produces: `htpc-cache-key.pub` content (a `key-name:base64` line) → `nix.settings.trusted-public-keys` in Task 2; `htpc-deploy.pub` → the `deploy` user's `authorizedKeys` in Task 2 (and root's on the installer ISO in Task 3); both private halves in 1Password → masked GitLab CI variables in Task 13.

Ordering matters here and the spec calls it out (runbook step 3-4): the **first** generation deployed to the box must already carry the trusted key and the deploy user, or CI's first push is refused. That is correct behaviour, but confusing if you hit it by accident.

- [ ] **Step 1: Generate the binary-cache signing keypair**

```bash
cd "$(mktemp -d)"
nix-store --generate-binary-cache-key htpc-cache-1 cache-priv.pem cache-pub.pem
cat cache-pub.pem
```

The public half is one line like `htpc-cache-1:AbCd…=`. Keep the terminal open for Step 3.

- [ ] **Step 2: Generate the deploy SSH keypair**

```bash
ssh-keygen -t ed25519 -N '' -C 'htpc deploy (gitlab ci)' -f ./htpc-deploy
cat htpc-deploy.pub
```

- [ ] **Step 3: Store both private halves in 1Password**

```bash
op item create --category "Secure Note" --title "htpc-cache-signing-key" \
  --vault Homelab \
  "private[password]=$(cat cache-priv.pem)" \
  "public[text]=$(cat cache-pub.pem)"

op item create --category "Secure Note" --title "htpc-deploy-ssh-key" \
  --vault Homelab \
  "private[password]=$(cat htpc-deploy)" \
  "public[text]=$(cat htpc-deploy.pub)"
```

- [ ] **Step 4: Destroy the local copies**

```bash
cd - >/dev/null
rm -rf "$OLDPWD"
```

- [ ] **Step 5: Record the two public halves where Task 2 can reach them**

Paste both public lines into the working notes for this plan (or straight into `nix/roles/base.nix` when Task 2 runs). They are public — committing them is the point.

No commit in this task.

---

## Task 2: Add the HTPC to the existing flake

**Files:**
- Modify: `nix/machines.nix` (add the `htpc` entry)
- Modify: `nix/roles/base.nix` (paste the two public keys from Task 1)
- Create: `nix/hosts/htpc/default.nix`
- Create: `nix/hosts/htpc/hardware.nix`
- Create: `nix/hosts/htpc/disko.nix`

**Interfaces:**
- Consumes: the flake scaffolding the **herdr** plan already landed — `flake.nix` with `mkMachine`, `nix/lib/registry.nix`, `nix/roles/{default,base}.nix`, `nix/profiles/{default,metal,lxc}.nix`, `nix/machines.nix`, `nix/tests/registry.nix`, and the `result*` entries in `.gitignore`. Also the two public keys (Task 1).
- Produces: `nixosConfigurations.htpc`; the `rpool` ZFS layout and `networking.hostId` that Task 3's ISO and `nixos-anywhere` run both depend on; the `roles.<name>` option namespace convention that Tasks 4, 7, 9 and 14 each add one entry to.

The registry, the shared `base` role and the flake itself are no longer this
task's work — the herdr plan built them, and this task adds a host to them. What
remains is genuinely HTPC-specific: the disk, the hardware, and the two public
keys that make the *first* generation deployed to the box already trust CI.

`kind = "metal"` is the load-bearing word in the machine entry. It selects
`nix/profiles/metal.nix`, which is what brings in disko, systemd-boot and EFI
variable access — none of which a container may have, because nixpkgs'
`proxmox-lxc` profile and a bootloader both define
`system.build.installBootLoader`, an option with no merge function.

Nothing here needs the hardware. The disk layout is **declared**, not scanned, so
`nixosConfigurations.htpc` builds completely on the laptop — which is what lets
Task 3 install by copying a finished closure rather than by running a generator
on the box.

- [ ] **Step 1: Confirm the shared scaffolding is present and has the shape this plan assumes**

```bash
ls flake.nix nix/lib/registry.nix nix/roles/default.nix nix/roles/base.nix \
   nix/profiles/default.nix nix/profiles/metal.nix nix/profiles/lxc.nix nix/machines.nix
nix eval --json .#nixosConfigurations --apply builtins.attrNames
grep -nE '^[[:space:]]*(boot\.loader|system\.stateVersion)' nix/roles/base.nix
```

Expected: every file present; at least one machine already declared; and the
`grep` finds **nothing**.

If `base.nix` does carry `boot.loader.*` or `system.stateVersion`, stop and move
them first — into `nix/profiles/metal.nix` and the per-host file respectively.
A container importing a base role that sets `boot.loader.*` does not warn, it
fails to evaluate with a definition conflict on `system.build.installBootLoader`.

- [ ] **Step 2: Add the machine**

In `nix/machines.nix`, alongside the entries already there:

```nix
  htpc = {
    system = "x86_64-linux";
    # metal, so the machine gets disko, systemd-boot and EFI variable access
    # from nix/profiles/metal.nix. An LXC gets none of those and needs no
    # disko.nix or hardware.nix at all.
    kind = "metal";
    roles = [ ];
  };
```

`base` is implicit and is never listed. The roles list fills up in Tasks 4, 7,
9 and 14.

- [ ] **Step 3: Paste the Task 1 public keys into the shared `base` role**

This is the only edit `nix/roles/base.nix` needs, and both halves are public —
committing them is the point. Do **not** add `boot.loader.*` or
`system.stateVersion` while you are in here; they live in
`nix/profiles/metal.nix` and `nix/hosts/htpc/default.nix` now.

```nix
  # CI's account. It gets no shell privileges of its own; the single sudo
  # entry it needs (htpc-stage) belongs to the staged-updates role in Task 14,
  # which is what owns that command.
  users.users.deploy = {
    isNormalUser = true;
    description = "CI closure receiver";
    openssh.authorizedKeys.keys = [
      "REPLACE-WITH-htpc-deploy.pub-FROM-TASK-1"
    ];
  };

  nix.settings.trusted-public-keys = [
    "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    # The builder's public half. A closure signed by it is accepted from an
    # untrusted user; anything else is refused. This is the whole reason a
    # stolen deploy key uploads bytes the box will not run, rather than
    # granting root.
    "REPLACE-WITH-cache-pub.pem-FROM-TASK-1"
  ];
```

If `users.users.deploy` is not in `base.nix` yet, add the block above as
written. If it is, replace the placeholder key only.

Ordering matters here and the spec calls it out (runbook step 3-4): the
**first** generation deployed to the box must already carry the trusted key and
the deploy user, or CI's first push is refused. That is correct behaviour, but
confusing if you hit it by accident.

- [ ] **Step 4: Declare the disk layout**

Create `nix/hosts/htpc/disko.nix`. This replaces the `hardware-configuration.nix`
that `nixos-generate-config` would have scanned off the box: disko generates
`fileSystems` from this declaration, so the machine evaluates before the machine
exists.

```nix
# The disk, declared rather than discovered. disko turns this into both the
# partitioning script the installer runs and the `fileSystems` entries the
# system boots with, so there is exactly one description of the layout and no
# generated file to copy off the box and keep in sync.
#
# Reachable only because nix/machines.nix says kind = "metal"; the disko
# module itself comes from nix/profiles/metal.nix.
{
  disko.devices = {
    disk.main = {
      type = "disk";
      # Confirmed against the real box in Task 3 Step 4 before anything is
      # written. If the box names its disk differently, this line is the only
      # thing that changes.
      device = "/dev/nvme0n1";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              # systemd-boot refuses an ESP that is world-readable.
              mountOptions = [ "umask=0077" ];
            };
          };
          zfs = {
            size = "100%";
            content = {
              type = "zfs";
              pool = "rpool";
            };
          };
        };
      };
    };

    zpool.rpool = {
      type = "zpool";
      options = {
        ashift = "12";
        autotrim = "on";
      };
      rootFsOptions = {
        compression = "zstd";
        # posixacl + xattr=sa are what systemd-journald wants; without them it
        # logs a warning on every boot and ACLs silently do not work.
        acltype = "posixacl";
        xattr = "sa";
        "com.sun:auto-snapshot" = "false";
        mountpoint = "none";
      };

      # Separate datasets so /nix can drop atime and so a future snapshot
      # policy can treat state differently from the store.
      datasets = {
        root = {
          type = "zfs_fs";
          mountpoint = "/";
          options.mountpoint = "legacy";
        };
        nix = {
          type = "zfs_fs";
          mountpoint = "/nix";
          options = {
            mountpoint = "legacy";
            atime = "off";
          };
        };
        var = {
          type = "zfs_fs";
          mountpoint = "/var";
          options.mountpoint = "legacy";
        };
        home = {
          type = "zfs_fs";
          mountpoint = "/home";
          options.mountpoint = "legacy";
        };
      };
    };
  };
}
```

- [ ] **Step 5: Write the hardware profile and the host index**

Create `nix/hosts/htpc/hardware.nix`:

```nix
# What is true of this box's hardware and nothing else's. Hand-written rather
# than generated: with disko owning the filesystems, everything
# nixos-generate-config would have produced beyond them is this short.
{ lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    "nvme"
    "usb_storage"
    "usbhid"
    "sd_mod"
  ];
  boot.kernelModules = [ "kvm-intel" ];

  hardware.cpu.intel.updateMicrocode = lib.mkDefault true;

  # ZFS refuses to import a pool last touched by a different host unless it is
  # forced, and it identifies a host by this. Fixed rather than random so the
  # installer ISO and the installed system agree and no import is ever forced.
  networking.hostId = "8f3a1c2d";
  boot.supportedFilesystems.zfs = true;

  # ZFS is an out-of-tree module, so it pins the kernel. Staying on the LTS
  # default is what keeps a nixpkgs bump from failing to build; nixpkgs' own
  # assertion catches the case where it would.
  services.zfs.autoScrub.enable = true;
  services.zfs.trim.enable = true;
}
```

Create `nix/hosts/htpc/default.nix`:

```nix
# Everything host-specific, in one import. mkMachine imports this directory,
# so adding a file here needs no change to the flake.
{
  imports = [
    ./hardware.nix
    ./disko.nix
  ];

  # A statement about which release this machine's state was created under,
  # not a version to keep current -- changing it later migrates nothing. It
  # lives here rather than in the shared base role because it is per-machine:
  # a box installed next year says something else, and one fleet-wide value
  # would silently be wrong for the second machine that ever appears.
  system.stateVersion = "26.05";
}
```

- [ ] **Step 6: Verify the machine evaluates and builds — with no hardware present**

Run: `nix build -L .#nixosConfigurations.htpc.config.system.build.toplevel`
Expected: a `result` symlink to a `…-nixos-system-htpc-26.05…` store path. This
is the payoff of declaring the disk instead of scanning it: the box does not
exist yet.

Then confirm disko really produced the filesystems, rather than them being
silently absent:

```bash
nix eval --json .#nixosConfigurations.htpc.config.fileSystems \
  --apply 'fs: builtins.mapAttrs (_: v: { inherit (v) device fsType; }) fs'
```

Expected: `/`, `/nix`, `/var` and `/home` on `fsType` `zfs` with `rpool/…`
devices, and `/boot` on `vfat`. An empty attrset means `nix/hosts/htpc/` is not
being imported — check the `./nix/hosts/${hostname}` line in `mkMachine`. A
`disko` *option does not exist* error instead means the machine entry is missing
`kind = "metal"`, so the disko module was never brought in.

- [ ] **Step 7: Verify the profile split really holds**

The reason `kind` exists is that a bootloader and a container profile cannot
coexist. Prove the metal half is what is providing it, rather than something in
`base.nix`:

```bash
nix eval .#nixosConfigurations.htpc.config.boot.loader.systemd-boot.enable
grep -rn 'boot\.loader' nix/roles/ || echo "no bootloader assumptions in any role"
```

Expected: `true`, and the grep finding nothing. A role that sets `boot.loader.*`
is a container that will not evaluate.

- [ ] **Step 8: Verify the unknown-role error is what a human would want**

The registry is not new, but the HTPC is the first machine this plan puts
through it. Temporarily add `roles = [ { name = "kiosc"; } ];` to the `htpc`
entry in `nix/machines.nix`, then:

Run: `nix eval .#nixosConfigurations.htpc.config.system.build.toplevel 2>&1 | tail -3`
Expected: contains `machine 'htpc' lists unknown role(s): kiosc. Valid roles are: …`.

Revert `nix/machines.nix` to `roles = [ ]` before committing.

- [ ] **Step 9: Run the whole check suite**

Run: `nix flake check -L`
Expected: no output on success. `machine-htpc` joins the checks that were
already there, so this also proves the new host did not break any machine that
already existed.

- [ ] **Step 10: Commit**

```bash
git add nix/machines.nix nix/roles/base.nix nix/hosts/htpc
git commit -m "feat(nix): declare the HTPC as a metal machine

tfvars answers 'what machines exist and how do I reach them'; this
answers 'what this one does'. The flake, the role registry and the
shared base role already exist -- this adds a host to them.

kind = \"metal\" is the load-bearing word. It is what brings in disko,
systemd-boot and EFI variable access, and the split is not cosmetic:
nixpkgs' proxmox-lxc profile and a bootloader both define
system.build.installBootLoader, an option with no merge function, so a
container importing a base role that set boot.loader.* would not warn,
it would fail to evaluate outright.

The disk is declared with disko rather than scanned with
nixos-generate-config. That is what makes this commit buildable before
the hardware exists: one description of the layout produces both the
partitioning script and the fileSystems entries, and there is no
generated file to copy off the box and keep in sync afterwards.

Root is ZFS to match the rest of the fleet, and hostId is fixed rather
than random so the installer and the installed system agree and no pool
import is ever forced. stateVersion sits next to the host because it
describes when that machine's state was created, not the fleet's -- one
shared value is silently wrong for the second machine that appears.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Build the installer ISO and install the box **(partly human)**

**Files:**
- Create: `nix/installer.nix`
- Modify: `flake.nix` (add `nixosConfigurations.installer` and `packages.x86_64-linux.installer-iso`)
- Modify: `justfile` (add an `iso` recipe)

**Interfaces:**
- Consumes: the fleet SSH key and `networking.hostId` (Task 2); `nixosConfigurations.htpc` (Task 2).
- Produces: a booted, installed box reachable as `default-user@htpc.edholm.cc`; the wired NIC's MAC, which Task 5's tfvars entry and Task 12's WoL step both read.

Packer is deliberately not involved. This repo's Packer builds Proxmox templates by SSHing to a node and driving `qm`/`packer build` there; it has no bare-metal path, and NixOS builds installer images natively from this same flake. Keeping it in-flake means the installer and the installed system share one `flake.lock`.

The ISO is a **rescue image, not an installer**: it brings the box up on DHCP with sshd and the fleet key, and nothing else. The install itself runs from the laptop with `nixos-anywhere`, which is where the private `home-player` flake input already resolves — so no key ever has to be baked into an ISO.

- [ ] **Step 1: Write the installer image**

Create `nix/installer.nix`:

```nix
# A rescue image, not an installer. Its whole job is to get the box onto the
# network with sshd and the fleet key so `nixos-anywhere` can take over from
# the laptop -- which is where the private home-player input resolves, so no
# credential is ever written to removable media.
{
  lib,
  modulesPath,
  pkgs,
  ...
}:
{
  imports = [ (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix") ];

  networking.hostName = "htpc-installer";
  # Same id as the installed system, so importing rpool never has to be forced.
  networking.hostId = "8f3a1c2d";

  # The ISO must be able to create the pool nix/hosts/htpc/disko.nix declares.
  # If this ever fails to build, it is ZFS lagging the ISO's kernel: pin
  # `boot.kernelPackages = pkgs.linuxPackages;` (the LTS series) here.
  boot.supportedFilesystems.zfs = lib.mkForce true;

  # mkForce because the installation-device profile already sets this to "yes";
  # a key is on the image, a password is not.
  services.openssh.settings.PermitRootLogin = lib.mkForce "prohibit-password";
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEkdwh5G9JuqNpThbxYqP7RBT9CQJ1fkFeOGuP1sUrXK"
  ];

  # Enough to identify the disk and the NIC without carrying a laptop to the TV.
  environment.systemPackages = with pkgs; [
    ethtool
    gptfdisk
    pciutils
    usbutils
  ];

  isoImage.isoName = lib.mkForce "terranse-installer.iso";
}
```

- [ ] **Step 2: Expose it from the flake**

In `flake.nix`, add to the outputs attrset, after `nixosConfigurations`:

```nix
      # Not built by mkMachine: an installer has no roles and no disk of its
      # own, so it is a plain nixosSystem rather than a fleet machine.
      nixosConfigurations.installer = lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [ ./nix/installer.nix ];
      };

      packages.x86_64-linux.installer-iso =
        self.nixosConfigurations.installer.config.system.build.isoImage;
```

`nixosConfigurations` is defined once with `lib.mapAttrs mkMachine machines`, so this second definition has to be merged into it rather than written as a second attribute — change that line to:

```nix
      nixosConfigurations = lib.mapAttrs mkMachine machines // {
        installer = lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs; };
          modules = [ ./nix/installer.nix ];
        };
      };

      packages.x86_64-linux.installer-iso =
        self.nixosConfigurations.installer.config.system.build.isoImage;
```

The `checks` attrset already filters `nixosConfigurations` by `system`, and the installer is `x86_64-linux`, so it would otherwise be built as a check named `machine-installer`. Exclude it by name — change the `filterAttrs` predicate to:

```nix
        ) (lib.filterAttrs (
          name: cfg: name != "installer" && cfg.pkgs.stdenv.hostPlatform.system == "x86_64-linux"
        ) self.nixosConfigurations)
```

- [ ] **Step 3: Add the `iso` recipe and build the image**

In `justfile`, next to the other Nix recipes:

```just
# Build the terranse rescue/installer ISO. Same flake as the machines it
# installs, so the installer and the installed system share one flake.lock.
iso:
    nix build .#installer-iso
    @ls -lh result/iso/
```

Run: `just iso`
Expected: `result/iso/terranse-installer.iso`, roughly 1 GB. A build failure mentioning `zfs` and a kernel version is the case the comment in `nix/installer.nix` calls out — pin `boot.kernelPackages` there.

- [ ] **Step 4: Write it to a USB stick and boot the box** **(human)**

```bash
lsblk                      # identify the stick; get this wrong and you lose a disk
sudo dd if=result/iso/terranse-installer.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

Boot the HTPC from it. While you are physically at the box, **enable Wake-on-LAN in the BIOS** — it is the one step nothing later can do remotely. Look for "Wake on LAN", "Power On by PCI-E", or ErP/EuP, which must be **disabled** or it cuts standby power to the NIC.

- [ ] **Step 5: Find the box and confirm the disk and NIC** **(human)**

The installer registers itself over DHCP as `htpc-installer`. From the laptop:

```bash
getent hosts htpc-installer.edholm.cc || nmap -sn 192.168.1.0/24 | grep -B2 -i htpc
ssh root@htpc-installer.edholm.cc 'lsblk -dno NAME,SIZE,MODEL; ip -br link show | grep -v LOOPBACK'
```

Expected: one NVMe disk and one wired NIC. **Record two things**: the disk's device node and the NIC's MAC (Task 5 needs the MAC).

If the disk is not `/dev/nvme0n1`, change the `device =` line in `nix/hosts/htpc/disko.nix` now, re-run `nix build .#nixosConfigurations.htpc.config.system.build.toplevel`, and commit that one-line change before installing.

- [ ] **Step 6: Install** **(human)**

```bash
nix run github:nix-community/nixos-anywhere -- \
  --flake .#htpc \
  --build-on local \
  root@htpc-installer.edholm.cc
```

`--build-on local` is load-bearing: the closure must be built on the laptop, where the private `home-player` input resolves. (On older nixos-anywhere the flag is `--no-substitute-on-destination` plus building locally by default; if `--build-on` is rejected, drop it — local is the default there.)

Expected: it partitions per `disko.nix`, creates `rpool`, copies the closure, installs the bootloader, and reboots. This destroys everything on the target disk — that is the point, but read the device it prints before confirming.

- [ ] **Step 7: Verify the installed system is the one that was declared**

```bash
ssh default-user@htpc.edholm.cc 'hostname; sudo -n true && echo passwordless-sudo-ok'
ssh -o BatchMode=yes root@htpc.edholm.cc true; echo "root login exit: $?"
ssh default-user@htpc.edholm.cc 'zpool status rpool | head -12; zfs list -o name,used,compression'
ssh default-user@htpc.edholm.cc 'readlink -f /run/current-system'
nix build --no-link --print-out-paths .#nixosConfigurations.htpc.config.system.build.toplevel
```

Expected: `htpc`; `passwordless-sudo-ok`; a non-zero exit for root; `rpool` ONLINE with the four datasets and `zstd` compression; and the last two commands printing the **same** store path.

- [ ] **Step 8: Verify DNS registered the box under its own name**

Run: `getent hosts htpc.edholm.cc`
Expected: an address on `192.168.1.0/24`. If it returns the WAN address, the lease did not register — confirm `networking.useDHCP` really took and that nothing set a static address. (Note the fleet's known quirk: a machine can register under the *installer's* name until its first post-install lease; a reboot settles it.)

- [ ] **Step 9: Commit**

```bash
git add nix/installer.nix flake.nix flake.lock justfile nix/hosts/htpc/disko.nix
git commit -m "feat(nix): build the HTPC's installer from the same flake

Packer is not involved on purpose: this repo's Packer builds Proxmox
templates by SSHing to a node and driving qm, and has no bare-metal
path. NixOS builds installer images natively, and keeping it in-flake
means the installer and the system it installs share one flake.lock.

The image is a rescue image rather than an installer. It brings the box
up on DHCP with sshd and the fleet key and stops there; nixos-anywhere
then installs from the laptop, which is where the private home-player
input resolves. Nothing has to bake a credential onto removable media,
and re-installing is one command rather than a sequence of prompts.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

## Task 4: The `video` role

**Files:**
- Create: `nix/roles/video.nix`
- Modify: `nix/roles/default.nix`
- Modify: `nix/machines.nix`

**Interfaces:**
- Consumes: the registry (already in the repo) and the `roles.<name>` convention; `nixosConfigurations.htpc` (Task 2).
- Produces: `roles.video.enable` and `roles.video.driver` (enum, currently `"intel"` only); a working pipewire stack that Task 9's kiosk user needs for HDMI audio; a booted, reachable box.

- [ ] **Step 1: Write the `video` role**

Create `nix/roles/video.nix`:

```nix
# Hardware video decode and audio out. `driver` is an enum rather than a free
# string so a typo fails at evaluation with the valid values listed, instead
# of silently deploying a box with no VA-API.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.roles.video;
in
{
  options.roles.video = {
    enable = lib.mkEnableOption "hardware video acceleration and audio output";

    driver = lib.mkOption {
      type = lib.types.enum [ "intel" ];
      description = ''
        Which GPU stack to install. No default on purpose: a machine that
        enables this role must say which hardware it has.
      '';
      example = "intel";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (lib.mkIf (cfg.driver == "intel") {
        hardware.graphics = {
          enable = true;
          extraPackages = with pkgs; [
            # 13th-gen iGPU: iHD is the modern driver; vpl-gpu-rt is what
            # actually carries the AV1/HEVC decode blocks on Xe graphics.
            intel-media-driver
            vpl-gpu-rt
          ];
        };
        # WebKitGTK picks its VA-API driver from the environment, and gets it
        # wrong on Intel without this.
        environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";
        environment.systemPackages = [ pkgs.libva-utils ];
      })

      {
        services.pulseaudio.enable = false;
        security.rtkit.enable = true;
        services.pipewire = {
          enable = true;
          alsa.enable = true;
          alsa.support32Bit = true;
          pulse.enable = true;
        };
      }
    ]
  );
}
```

- [ ] **Step 2: Register it**

In `nix/roles/default.nix`, add one line:

```nix
{
  base = ./base.nix;
  video = ./video.nix;
}
```

- [ ] **Step 3: List it on the machine**

In `nix/machines.nix`, replace `roles = [ ];` with:

```nix
    roles = [
      { name = "video"; settings = { driver = "intel"; }; }
    ];
```

- [ ] **Step 4: Verify the enum rejects a bad driver**

Temporarily change `driver = "intel"` to `driver = "amd"`, then:

Run: `nix eval .#nixosConfigurations.htpc.config.system.build.toplevel 2>&1 | tail -3`
Expected: a message containing `one of "intel"`.

Change it back to `"intel"`.

- [ ] **Step 5: Build**

Run: `nix flake check -L`
Expected: no output.

- [ ] **Step 6: Dry-run the activation against the real box**

The `base` role disabled root SSH on the very first boot, so every deploy from here on goes in as `default-user` and escalates with `--sudo` (older `nixos-rebuild` spells this `--use-remote-sudo`).

Run: `nixos-rebuild dry-activate --flake .#htpc --target-host default-user@htpc.edholm.cc --sudo`
Expected: a list of units that would be started/restarted, and no errors. This is the spec's "dry-activate against the real box before the first live switch".

- [ ] **Step 7: Deploy for real**

Run: `nixos-rebuild switch --flake .#htpc --target-host default-user@htpc.edholm.cc --sudo`
Expected: ends with `activating the configuration...` and no failures.

- [ ] **Step 8: Verify VA-API and audio came up**

```bash
ssh default-user@htpc.edholm.cc 'vainfo 2>&1 | head -5'
ssh default-user@htpc.edholm.cc 'systemctl --user is-active pipewire.service || systemctl is-active pipewire.service'
```

Expected: `vainfo` prints `Driver version: Intel iHD driver …` and lists profiles; pipewire is `active`.

If `vainfo` reports `libva error: /dev/dri/renderD128 not found`, the iGPU is disabled in the BIOS or the kernel picked no driver — check `ssh default-user@htpc.edholm.cc 'ls /dev/dri'` before touching the role.

- [ ] **Step 9: Commit**

```bash
git add nix/roles/video.nix nix/roles/default.nix nix/machines.nix
git commit -m "feat(nix): give the HTPC hardware decode and audio

A 13th-gen iGPU needs intel-media-driver plus vpl-gpu-rt for the AV1 and
HEVC blocks, and WebKitGTK will not find either without LIBVA_DRIVER_NAME
pointing at iHD.

driver is an enum rather than a free string so a typo fails at
evaluation with the valid values listed, instead of deploying a box that
software-decodes everything and nobody notices until the TV stutters.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: The tfvars identity entry and its DHCP reservation

**Files:**
- Modify: `tofu/deployments/edholm/configurations.tfvars` (add an `htpc` host, after the `workstation` block)
- Modify: `tofu/deployments/edholm/defaults.tf:44-60` (add `host_reserved_ips`)
- Modify: `tofu/deployments/edholm/main.tf:92-113` (locals) and `:135-160` (`module "opnsense_networking"`)

**Interfaces:**
- Consumes: the MAC recorded in Task 3 Step 5.
- Produces: `hosts.htpc.mac` in tfvars — the single declaration that both the DHCP reservation and Task 12's WoL step read; a reserved `192.168.1.51`; an `ansible_host` inventory entry in group `physical_hosts` with no plays attached.

The `opnsense-networking` module itself needs **no** change: its `reservations` variable is already `map(object({ mac, ip }))` keyed by name and has nothing LXC-specific in it. What is missing is the deployment-level wiring that feeds it.

- [ ] **Step 1: Add the host entry**

In `tofu/deployments/edholm/configurations.tfvars`, after the closing `}` of the `workstation` block and before the final `}`, add:

```hcl
  # Bare metal, no hypervisor. tfvars declares identity only -- what this
  # machine actually runs is declared in nix/machines.nix, the same way
  # docker_services names a bundle whose contents live elsewhere.
  #
  # No lxcs, no vms and no host_roles, so this entry instantiates no Proxmox
  # module and generates no Ansible plays. It buys exactly two things: an
  # inventory entry, and the DHCP reservation below.
  htpc = {
    ansible_host = "htpc.edholm.cc"
    ansible_user = "default-user"
    kind         = "nixos"
    # The wired NIC's MAC, read from the box at install. The DHCP reservation
    # and CI's wake-on-LAN step both read this one declaration.
    mac = "REPLACE-WITH-THE-MAC-FROM-TASK-3-STEP-5"
  }
```

- [ ] **Step 2: Add the reserved-address variable**

In `tofu/deployments/edholm/defaults.tf`, after the `lxc_reserved_ips` variable, add:

```hcl
variable "host_reserved_ips" {
  type        = map(string)
  description = <<-EOT
    Fixed address per bare-metal host that declares a `mac`. Separate from
    lxc_reserved_ips because those MACs are derived from the container name in
    proxmox-container; a physical NIC's MAC is a fact about hardware and has
    to be declared.
  EOT
  default = {
    htpc = "192.168.1.51"
  }
}
```

- [ ] **Step 3: Collect the host MACs into a local**

In `tofu/deployments/edholm/main.tf`, inside the `locals` block that already defines `all_lxc_names` / `lxc_macs` / `bundle_to_container` (around line 92), add after `lxc_macs`:

```hcl
  # Bare-metal hosts that declared a MAC. Nothing derives these -- a physical
  # NIC's address is a fact, so the tfvars entry is the source of truth for
  # both the reservation below and CI's wakeonlan step.
  host_macs = {
    for host_key, host in var.hosts : host_key => host.mac
    if try(host.mac, null) != null
  }
```

- [ ] **Step 4: Fold them into the reservations**

In the same file, replace the `reservations` argument of `module "opnsense_networking"`:

```hcl
  reservations = merge(
    {
      for name, ip in var.lxc_reserved_ips : name => {
        mac = local.lxc_macs[name]
        ip  = ip
      } if contains(keys(local.lxc_macs), name)
    },
    {
      for name, ip in var.host_reserved_ips : name => {
        mac = local.host_macs[name]
        ip  = ip
      } if contains(keys(local.host_macs), name)
    },
  )
```

- [ ] **Step 5: Guard against a host and a container claiming the same name**

Still in `main.tf`, next to the existing `terraform_data "lxc_name_uniqueness_guard"`, add:

```hcl
# A reservation is keyed by name and a name is a DNS record, so a container
# and a bare-metal host sharing one would silently overwrite each other's
# address. merge() would pick the host's and say nothing.
resource "terraform_data" "reservation_name_uniqueness_guard" {
  input = sort(concat(keys(local.lxc_macs), keys(local.host_macs)))

  lifecycle {
    precondition {
      condition = length(setintersection(keys(local.lxc_macs), keys(local.host_macs))) == 0
      error_message = "A bare-metal host and an LXC share a name, so their DHCP reservations would collide: ${jsonencode(setintersection(keys(local.lxc_macs), keys(local.host_macs)))}"
    }
  }
}
```

- [ ] **Step 6: Validate**

Run: `just validate-tofu`
Expected: `Success! The configuration is valid.` for both deployments.

- [ ] **Step 7: Plan and read the diff before applying**

Run: `cd tofu/deployments/edholm && tofu plan -var-file=configurations.tfvars`
Expected: exactly one resource to add — `module.opnsense_networking.opnsense_dnsmasq_host.reservation["htpc"]` — plus the two `terraform_data` guards updating. **No** container or VM changes. If the plan wants to touch anything else, stop and investigate before applying.

- [ ] **Step 8: Apply**

Run: `just apply-tofu edholm`
Expected: `Apply complete! Resources: 1 added, …`.

- [ ] **Step 9: Verify the reservation took, and that the box now holds it**

```bash
ssh -p 2223 root@opnsense.edholm.cc 'sh -c "grep -r htpc /usr/local/etc/dnsmasq.conf.d/ || true"'
ssh default-user@htpc.edholm.cc 'ip -4 addr show scope global | grep inet'
```

Expected: a dnsmasq entry pairing the MAC with `192.168.1.51`. The box keeps its old lease until it renews — reboot it (`ssh default-user@htpc.edholm.cc sudo reboot`) and re-check; it should come back on `.51`.

- [ ] **Step 10: Verify the inventory sees it and no play targets it**

```bash
cd ansible && ansible-inventory -i inventory/edholm.yaml --host htpc
grep -c 'hosts: htpc' playbooks/edholm.yaml || true
```

Expected: the host prints with `ansible_host: htpc.edholm.cc` and `ansible_user: default-user`; the grep finds `0`. A NixOS box must never be targeted by an Ansible play — its configuration is declared in Nix.

- [ ] **Step 11: Commit**

```bash
git add tofu/deployments/edholm/configurations.tfvars \
        tofu/deployments/edholm/defaults.tf \
        tofu/deployments/edholm/main.tf
git commit -m "feat(tofu): declare the HTPC's identity and pin its address

tfvars answers what machines exist and how to reach them; nix/machines.nix
answers what they do. The htpc entry therefore carries no roles: with no
lxcs, vms or host_roles it instantiates no Proxmox module and generates
no plays, which is what we want for a machine Ansible must never touch.

The DHCP reservation was not free, contrary to expectation. The
opnsense-networking module is already generic, but the deployment sourced
MACs exclusively from module.proxmox-lxc and keyed addresses off
lxc_reserved_ips. Bare metal cannot derive a MAC from a name, so
host_reserved_ips and local.host_macs are new, and a guard rejects a
host and a container claiming the same reservation name -- merge() would
otherwise pick one and say nothing.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Put both repos on gitlab.com **(human)**

**Files:** none in either repo — this task only moves remotes and sets CI variables.

**Interfaces:**
- Produces: `gitlab.com/yarcod/terranse` and `gitlab.com/yarcod/home-player`, both private; the CI variables Task 13's pipelines read; the `git+ssh://` URL that Task 7 adds as a flake input.

This has to happen before Task 7 because `flake.nix` gains `home-player` as a `git+ssh` input, and that URL must resolve from both the laptop and the runner. The move is to GitLab and not GitHub because the build has to happen *on the LAN* to reach the box: the gitlab-runner LXC polls outward and so works from behind NAT, whereas GitHub-hosted runners cannot reach the LAN at all, and a self-hosted GitHub runner would cost a new docker template, a new role and a second CI dialect for no capability gain.

- [ ] **Step 1: Create the group and the two private projects**

In the gitlab.com web UI, create group **`yarcod`**, then two **private** projects inside it: `terranse` and `home-player`. Do not initialise either with a README — both already have history.

- [ ] **Step 2: Point terranse at it**

From `/home/daniele/Repos/terranse`:

```bash
git remote rename origin github
git remote add origin git@gitlab.com:yarcod/terranse.git
git push -u origin --all
git push origin --tags
```

The GitHub remote is kept under the name `github` rather than deleted — nothing depends on it, and it costs nothing to be able to look back.

- [ ] **Step 3: Give home-player a remote for the first time**

home-player has no remote at all today. From `/home/daniele/Repos/home-player`:

```bash
git remote add origin git@gitlab.com:yarcod/home-player.git
git push -u origin master
git push origin --all
```

- [ ] **Step 4: Verify both resolve over SSH**

```bash
git ls-remote git@gitlab.com:yarcod/terranse.git HEAD
git ls-remote git@gitlab.com:yarcod/home-player.git HEAD
```

Expected: a SHA and `HEAD` from each. If SSH is refused, add your key under gitlab.com → User Settings → SSH Keys first.

- [ ] **Step 5: Create the deploy key that lets CI read home-player**

terranse's pipeline evaluates a `git+ssh` flake input pointing at the private `home-player` project, so the runner needs read access to it.

In `gitlab.com/yarcod/home-player` → Settings → Repository → **Deploy keys**, add the **public** half of the `htpc-deploy` key created in Task 1 (`op item get htpc-deploy-ssh-key --fields public --reveal`), read-only, titled `terranse-ci`.

The same keypair is reused for the box's `deploy` user; both are "the CI's identity", and one key is one thing to rotate.

- [ ] **Step 6: Set the CI variables on `edholm/terranse`**

Settings → CI/CD → Variables. All four **masked**, none protected (the default branch is not marked protected in this setup — if you do protect `main`, mark them protected too or the deploy job gets empty values).

| Key | Value | Notes |
|---|---|---|
| `DEPLOY_SSH_KEY` | `op item get htpc-deploy-ssh-key --fields private --reveal \| base64 -w0` | base64 so the multi-line PEM survives a masked variable |
| `CACHE_SIGNING_KEY` | `op item get htpc-cache-signing-key --fields private --reveal` | single line already |
| `CI_PUSH_TOKEN` | a project access token, scope `write_repository`, role Maintainer | lets the deploy job push the `flake.lock` bump back |
| `KNOWN_HOSTS` | output of the command in Step 7 | |

`deploy-htpc` also runs `sed`, which the `nixos/nix` image does not ship — the pipeline's `nix shell` line carries `nixpkgs#gnused` for that reason. Do not trim it.

- [ ] **Step 7: Produce the `KNOWN_HOSTS` value**

```bash
ssh-keyscan gitlab.com htpc.edholm.cc 2>/dev/null
```

Paste the whole output as the `KNOWN_HOSTS` variable. Without it the runner's `git+ssh` fetch and the closure push both hang on host-key confirmation inside a container with no TTY — the spec names this as the failure most likely to bite in this phase.

- [ ] **Step 8: Allow home-player's job token to trigger terranse**

**Do NOT create a `TERRANSE_TRIGGER_TOKEN` variable.** An earlier draft of this plan said to, and it would be dead configuration: GitLab's `trigger:` keyword — the multi-project syntax `.gitlab-ci.yml` uses — has no `token:` field. It authenticates with the upstream job's built-in `CI_JOB_TOKEN`. A hand-made pipeline trigger token is only ever read by the separate REST endpoint (`POST .../trigger/pipeline`), which nothing here calls.

The real prerequisite is the job-token allowlist, and without it the trigger job fails with a permissions error that looks nothing like a missing variable:

In `gitlab.com/yarcod/terranse` → Settings → CI/CD → **Token Access** (job token permissions), add `yarcod/home-player` to the allowlist of projects permitted to trigger it. Confirm the account running the pipeline has at least Developer on `terranse`.

- [ ] **Step 9: Update the stale clone URL in the README**

In `/home/daniele/Repos/terranse/README.md`, change `git clone https://github.com/terranse/terranse.git` to `git clone git@gitlab.com:yarcod/terranse.git`, then:

```bash
git add README.md
git commit -m "docs: point the clone URL at gitlab

The build has to happen on the LAN to reach the HTPC, and the
gitlab-runner LXC polls outward so it works from behind NAT. GitHub's
hosted runners cannot reach the LAN at all.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
git push
```

---

## Task 7: The `home-player` role

**Files:**
- Create: `nix/roles/home-player.nix`
- Modify: `flake.nix` (add the `home-player` input)
- Modify: `nix/roles/default.nix`
- Modify: `nix/machines.nix`

**Interfaces:**
- Consumes: `inputs.home-player.nixosModules.default` — options `services.home-player.{enable,environmentFile,settings,web.enable,wakeOnLan.enable}`; it creates `home-player-backend.service` running as system user `home-player`, and `home-player-wol.service`.
- Produces: `roles.home-player.{enable,web.enable,secretsFile,jellyfinUrl,sonarrUrl,radarrUrl}`; the backend listening on `127.0.0.1:9600` (Task 14's policy engine polls `/health` and `/system/activity` there); the secrets path `/var/lib/home-player-secrets/env` (Task 8 writes it); WoL armed at every boot (Task 12's `ship.sh` depends on it).

- [ ] **Step 1: Add the flake input**

In `flake.nix`, inside `inputs`, after `home-manager`:

```nix
    # Deliberately NOT `inputs.nixpkgs.follows`. home-player's own pipeline
    # runs `nix flake check` against its locked nixpkgs; overriding it here
    # would deploy a combination nobody tested. The cost is a second nixpkgs
    # in the closure, which the binary cache absorbs.
    home-player.url = "git+ssh://git@gitlab.com/yarcod/home-player.git";
```

- [ ] **Step 2: Lock it**

Run: `nix flake update home-player`
Expected: `flake.lock` gains a `home-player` node with a `rev`. (`nix flake update <input>` is the current form; the older `nix flake lock --update-input` is deprecated.)

- [ ] **Step 3: Write the role**

Create `nix/roles/home-player.nix`:

```nix
# The backend, as a system service. The kiosk shell that talks to it is the
# `kiosk` role's business.
{
  config,
  lib,
  inputs,
  ...
}:
let
  cfg = config.roles.home-player;
in
{
  imports = [ inputs.home-player.nixosModules.default ];

  options.roles.home-player = {
    enable = lib.mkEnableOption "the Home Player backend";

    web.enable = lib.mkEnableOption ''
      serving the built web bundle over nginx.

      Local or tunnelled debugging ONLY. The bundle has
      `http://127.0.0.1:9600` compiled into it and the backend allows only
      loopback and `tauri://` CORS origins, so a browser on another device
      calls its own loopback and is refused. This is not a remote-access
      feature
    '';

    secretsFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/home-player-secrets/env";
      description = ''
        KEY=value file holding the provider API tokens, placed out of band by
        `just secrets htpc`.

        A **string**, never a bare Nix path: `/var/lib/...` written unquoted
        would be copied into the store at evaluation time, which both leaks
        the intent and fails on a builder where the file does not exist.
      '';
    };

    jellyfinUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://jellyfin.edholm.cc";
      description = "Base URL of the Jellyfin server.";
    };

    sonarrUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://sonarr.edholm.cc";
      description = "Base URL of Sonarr.";
    };

    radarrUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://radarr.edholm.cc";
      description = "Base URL of Radarr.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.home-player = {
      enable = true;

      # No `-` prefix: a missing secrets file must fail the unit loudly
      # rather than start a backend with no API tokens, which fails later,
      # quieter, and on the television.
      environmentFile = cfg.secretsFile;

      web.enable = cfg.web.enable;

      # Re-arm magic-packet WoL on the wired NIC at every boot, so CI can wake
      # the box. The BIOS half is set by hand once (see the bootstrap runbook).
      wakeOnLan.enable = true;

      settings = {
        backend = {
          # The backend has no authentication on any route -- /proxy/... will
          # forward arbitrary upstream paths with the API token attached.
          # Loopback only; the kiosk shell is the only client.
          host = "127.0.0.1";
          port = 9600;
        };

        providers = {
          # The key is `api_token`. home-player's own module example says
          # `api_key`, which the providers do not read
          # (providers/jellyfin.py does config["api_token"]).
          jellyfin = {
            url = cfg.jellyfinUrl;
            api_token = "\${env:JELLYFIN_API_KEY}";
          };
          sonarr = {
            url = cfg.sonarrUrl;
            api_token = "\${env:SONARR_API_KEY}";
          };
          radarr = {
            url = cfg.radarrUrl;
            api_token = "\${env:RADARR_API_KEY}";
          };
        };
      };
    };
  };
}
```

- [ ] **Step 4: Register and list it**

`nix/roles/default.nix`:

```nix
{
  base = ./base.nix;
  home-player = ./home-player.nix;
  video = ./video.nix;
}
```

`nix/machines.nix`, in the `roles` list after `video`:

```nix
      {
        name = "home-player";
        settings = {
          web.enable = true;
          jellyfinUrl = "https://jellyfin.edholm.cc";
          sonarrUrl = "https://sonarr.edholm.cc";
          radarrUrl = "https://radarr.edholm.cc";
        };
      }
```

- [ ] **Step 5: Verify the environment file did not land in the store**

Run: `nix eval --raw .#nixosConfigurations.htpc.config.systemd.services.home-player-backend.serviceConfig.EnvironmentFile`
Expected: `/var/lib/home-player-secrets/env` — **not** a `/nix/store/…` path. A store path here means a bare path literal was used and the value was copied in at evaluation time.

- [ ] **Step 6: Verify the rendered config carries env references, not values**

Run: `nix eval --raw .#nixosConfigurations.htpc.config.services.home-player.settings.providers.jellyfin.api_token`
Expected: the literal `${env:JELLYFIN_API_KEY}`.

- [ ] **Step 7: Build and deploy**

```bash
nix flake check -L
nixos-rebuild switch --flake .#htpc --target-host default-user@htpc.edholm.cc --sudo
```

Expected: the check passes; the switch reports `home-player-backend.service` and `home-player-wol.service` being started.

- [ ] **Step 8: Verify the backend fails loudly with no secrets file**

Run: `ssh default-user@htpc.edholm.cc 'systemctl status home-player-backend.service --no-pager | head -20'`
Expected: `Failed to load environment files: No such file or directory` and the unit in `failed`. **This is the correct state until Task 8 runs** — record it and move on.

- [ ] **Step 9: Verify WoL is armed**

```bash
ssh default-user@htpc.edholm.cc 'systemctl status home-player-wol.service --no-pager | tail -5'
ssh default-user@htpc.edholm.cc 'sudo ethtool $(ip -br link | awk "/^en/{print \$1; exit}") | grep Wake-on'
```

Expected: the unit logs `armed magic-packet WoL on <iface>`, and `ethtool` reports `Wake-on: g`.

- [ ] **Step 10: Commit**

```bash
git add flake.nix flake.lock nix/roles/home-player.nix nix/roles/default.nix nix/machines.nix
git commit -m "feat(nix): run the home-player backend on the HTPC

home-player is consumed as a git+ssh flake input whose nixpkgs is
deliberately not followed: its own pipeline runs nix flake check against
its locked nixpkgs, so overriding it here would deploy a combination
nobody tested. The cost is a second nixpkgs in the closure and the
binary cache absorbs it.

Two traps in this role specifically. environmentFile is a quoted string,
not a bare Nix path -- a bare /var/lib/... is copied into the store at
evaluation time, which leaks the intent and fails on a builder where the
file does not exist. And the provider config key is api_token, not
api_key; the example in home-player's own module says api_key, which
providers/jellyfin.py would KeyError on.

There is no '-' prefix on environmentFile on purpose: a missing secrets
file must fail the unit loudly rather than start a backend with no API
tokens, which fails later, quieter, and on the television.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: The secrets template and `just secrets`

**Files:**
- Create: `nix/hosts/htpc/secrets.env.tpl`
- Modify: `justfile` (add a `secrets` recipe after `setup-secrets`)

**Interfaces:**
- Consumes: `roles.home-player.secretsFile` = `/var/lib/home-player-secrets/env` (Task 7).
- Produces: `just secrets <machine>` — idempotent, and therefore the entire rotation procedure.

Ansible was considered and rejected for this. Its advantage is idempotence across a fleet, which does not apply to one file on one host, and it would require `python3` on an otherwise minimal NixOS box purely to place it. The template is kept per-host so that promoting this to a generic play, if a second Nix machine appears, is mechanical.

- [ ] **Step 1: Write the template**

Create `nix/hosts/htpc/secrets.env.tpl`. It is checked in on purpose: it is literally an `op inject` template, so it contains references and never values.

```
# op inject template -- references only, never values. Rendered on the laptop
# (where `op` is already unlocked) and piped over SSH, so no service-account
# token has to exist anywhere on the LAN.
#
#   just secrets htpc
#
# Re-running is the whole rotation procedure.
JELLYFIN_API_KEY=op://Homelab/jellyfin/api_key
SONARR_API_KEY=op://Homelab/sonarr/api_key
RADARR_API_KEY=op://Homelab/radarr/api_key
```

- [ ] **Step 2: Add the recipe**

In `justfile`, after the existing `setup-secrets` recipe:

```just
# Render a NixOS host's op-inject secrets template and install it on the box.
# Idempotent -- re-running it is the entire rotation procedure.
secrets machine:
    #!{{ bash }}
    tpl="nix/hosts/{{ machine }}/secrets.env.tpl"
    if [[ ! -f "$tpl" ]]; then
      echo "No secrets template at $tpl" >&2
      exit 1
    fi
    # Values exist only in this pipe: never in the repo, never in the Nix
    # store, never in CI.
    op inject -i "$tpl" | ssh default-user@{{ machine }}.{{ domain }} \
      'sudo install -d -m 0700 -o root -g root /var/lib/home-player-secrets && \
       sudo install -m 0600 -o root -g root /dev/stdin /var/lib/home-player-secrets/env && \
       sudo systemctl restart home-player-backend.service'
    echo "secrets installed on {{ machine }}.{{ domain }}"
```

The file is `0600 root:root` and the unit runs as `home-player`; that is fine because systemd reads `EnvironmentFile=` as PID 1, before dropping privileges.

- [ ] **Step 3: Verify the template renders before shipping it anywhere**

Run: `op inject -i nix/hosts/htpc/secrets.env.tpl | sed 's/=.*/=<redacted>/'`
Expected: three lines, each `NAME=<redacted>`. If any line comes back with the `op://` reference intact, that item or field does not exist in the `Homelab` vault — fix the reference, not the template's shape.

- [ ] **Step 4: Install them**

Run: `just secrets htpc`
Expected: `secrets installed on htpc.edholm.cc`.

- [ ] **Step 5: Verify the backend now starts and answers**

```bash
ssh default-user@htpc.edholm.cc 'systemctl is-active home-player-backend.service'
ssh default-user@htpc.edholm.cc 'curl -fsS http://127.0.0.1:9600/health'
ssh default-user@htpc.edholm.cc 'sudo journalctl -u home-player-backend -n 30 --no-pager | grep -i "initialized"'
```

Expected: `active`; `{"status":"ok"}`; and `Provider jellyfin initialized` / `sonarr` / `radarr` — three lines. A provider logged as `Failed to initialize provider …` has a wrong URL or token; a provider *absent* from the log was never registered.

- [ ] **Step 6: Verify idempotence**

Run: `just secrets htpc && ssh default-user@htpc.edholm.cc 'sudo stat -c "%a %U:%G" /var/lib/home-player-secrets/env'`
Expected: `600 root:root`, and the backend still `active`.

- [ ] **Step 7: Verify no secret reached the repo**

Run: `grep -n 'op://' nix/hosts/htpc/secrets.env.tpl`
Expected: three lines, every value still an `op://` reference.

- [ ] **Step 8: Commit**

```bash
git add nix/hosts/htpc/secrets.env.tpl justfile
git commit -m "feat(nix): place the HTPC's provider tokens from 1Password

The template is checked in because it is literally an op inject template:
references, never values. Rendering happens on the laptop where op is
already unlocked, so no service-account token has to exist anywhere on
the LAN, and the values live only in the pipe -- not in the repo, not in
the Nix store, not in CI.

Ansible was considered and rejected. Its advantage is idempotence across
a fleet, which does not apply to one file on one host, and it would need
python3 on an otherwise minimal NixOS box purely to place it. Keeping the
template per-host means promoting this to a generic play, if a second Nix
machine ever appears, is mechanical.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: The `kiosk` role

**Files:**
- Create: `nix/roles/kiosk.nix`
- Modify: `nix/roles/default.nix`
- Modify: `nix/machines.nix`

**Interfaces:**
- Consumes: `inputs.home-manager.nixosModules.home-manager`; `inputs.home-player.homeModules.default`, which defines `services.home-player-shell.{enable,package,extraEnvironment,backend.*}` and creates the **user** unit `home-player-shell.service`, `PartOf`/`WantedBy` `graphical-session.target`.
- Produces: `roles.kiosk.{enable,user}`; a `tv` user whose `home-player-shell.service` user unit is what Task 14's watchdog checks with `systemctl --user --machine=tv@.host is-active home-player-shell.service`.

home-player's `nix/checks.nix` hard-asserts that `services.home-player-shell` has exactly the leaves `backend`, `enable`, `extraEnvironment`, `package` — do not expect any others.

- [ ] **Step 1: Write the role**

Create `nix/roles/kiosk.nix`:

```nix
# greetd autologs the TV user into cage; the shell itself is a home-manager
# user unit so it is a first-class systemd service the update watchdog can
# ask about, rather than a child process of the compositor.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.roles.kiosk;

  # cage sets WAYLAND_DISPLAY for its own child, but the user manager was
  # started by logind before any compositor existed and knows nothing about
  # it. Import it, start the target the shell unit is bound to, and then stay
  # alive: the shell has Restart=on-failure, so the compositor must NOT exit
  # when the shell briefly crashes.
  session = pkgs.writeShellScript "tv-session" ''
    ${pkgs.systemd}/bin/systemctl --user import-environment WAYLAND_DISPLAY XDG_RUNTIME_DIR
    ${pkgs.systemd}/bin/systemctl --user start graphical-session.target
    exec ${pkgs.coreutils}/bin/sleep infinity
  '';
in
{
  imports = [ inputs.home-manager.nixosModules.home-manager ];

  options.roles.kiosk = {
    enable = lib.mkEnableOption "the Home Player TV kiosk session";

    user = lib.mkOption {
      type = lib.types.str;
      default = "tv";
      description = "Account the kiosk session autologs into.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      isNormalUser = true;
      description = "TV kiosk session";
      extraGroups = [
        "video"
        "audio"
        "input"
        "render"
      ];
    };

    services.greetd = {
      enable = true;
      settings.default_session = {
        command = "${lib.getExe pkgs.cage} -s -- ${session}";
        user = cfg.user;
      };
    };

    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      extraSpecialArgs = { inherit inputs; };

      users.${cfg.user} = {
        imports = [ inputs.home-player.homeModules.default ];

        home.stateVersion = "26.05";

        services.home-player-shell = {
          enable = true;
          # The package wrapper already sets GDK_BACKEND and
          # WEBKIT_DISABLE_COMPOSITING_MODE; only the compositor socket has to
          # be named, and cage's first socket is wayland-1.
          extraEnvironment = {
            WAYLAND_DISPLAY = "wayland-1";
          };
        };

        # backend.enable stays off: on NixOS the system service from the
        # home-player role is the one that runs, and two backends would fight
        # over :9600.
      };
    };
  };
}
```

- [ ] **Step 2: Register and list it**

`nix/roles/default.nix`:

```nix
{
  base = ./base.nix;
  home-player = ./home-player.nix;
  kiosk = ./kiosk.nix;
  video = ./video.nix;
}
```

`nix/machines.nix`, after the `home-player` entry:

```nix
      { name = "kiosk"; }
```

- [ ] **Step 3: Build**

Run: `nix flake check -L`
Expected: no output. A failure mentioning `home.stateVersion` means home-manager's module was imported without the per-user config above.

- [ ] **Step 4: Deploy**

Run: `nixos-rebuild switch --flake .#htpc --target-host default-user@htpc.edholm.cc --sudo`
Expected: `greetd.service` started.

- [ ] **Step 5: Verify the session came up, from the TV and from SSH**

```bash
ssh default-user@htpc.edholm.cc 'systemctl is-active greetd.service'
ssh default-user@htpc.edholm.cc 'systemctl --user --machine=tv@.host is-active home-player-shell.service'
ssh default-user@htpc.edholm.cc 'systemctl --user --machine=tv@.host status home-player-shell.service --no-pager | tail -20'
```

Expected: `active` twice. Look at the TV itself: the Home Player home screen, full-screen, no decorations.

If the shell is `activating (auto-restart)`, read its journal. The usual causes are a missing GStreamer plugin (video renders as a black rectangle) or `WAYLAND_DISPLAY` naming a socket that does not exist. Check the real socket name with:

```bash
ssh default-user@htpc.edholm.cc 'sudo ls /run/user/$(id -u tv)/'
```

and correct `extraEnvironment.WAYLAND_DISPLAY` if cage named it something other than `wayland-1`.

- [ ] **Step 6: Verify a cold boot lands on the kiosk**

```bash
ssh default-user@htpc.edholm.cc sudo reboot
# wait for it to come back, then:
ssh default-user@htpc.edholm.cc 'systemctl --user --machine=tv@.host is-active home-player-shell.service'
```

Expected: `active`, with no keyboard touched, and the TV showing the home screen. **This is the end of phase 2** — the box does its job, deployed by hand.

- [ ] **Step 7: Commit**

```bash
git add nix/roles/kiosk.nix nix/roles/default.nix nix/machines.nix
git commit -m "feat(nix): autostart the Home Player kiosk on the TV

greetd autologs the tv user into cage, and the shell runs as a
home-manager user unit rather than as a child of the compositor. That
costs a session script but buys something the update policy needs: the
shell is a first-class systemd unit the watchdog can ask about, so
'the backend answers /health but the screen is blank' becomes at least
partly detectable.

The session script stays alive with sleep infinity instead of exec'ing
the shell, because the unit has Restart=on-failure -- a compositor that
exited with the shell would take the whole session down on the first
transient crash instead of letting systemd restart it.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: The binary cache — dataset, mount, and HTTP server

**Files:**
- Create: `ansible/roles/docker/templates/nix-cache.yaml.j2`
- Modify: `tofu/deployments/edholm/configurations.tfvars` (the `gitlab-runner` LXC block, ~line 169)

**Interfaces:**
- Consumes: the `docker` role's `service_mounts` fact (mount `name` → `path`, built in `ansible/roles/docker/tasks/apps.yaml:19-35`) and the `# caddy:expose` marker convention read by `tofu/modules/service-registry`.
- Produces: `https://nix-cache.edholm.cc` serving `/srv/nix-cache` — read by Task 14's boot-time fetch; `/srv/nix-cache` writable from inside the runner's job containers, which Tasks 11 and 12 depend on.

`nix copy --to file://` produces a valid binary cache on its own, so the serving host needs neither Nix nor a daemon — just static HTTP.

- [ ] **Step 1: Ask Daniele to create the dataset** **(human)**

Stop here and hand over. On the `workstation` Proxmox host (the runner's LXC lives there):

```bash
ssh root@workstation.netbird.cloud
zfs create -o compression=zstd -o atime=off nvmepool/nix-cache
zfs set quota=200G nvmepool/nix-cache
# The gitlab-runner LXC is unprivileged, so root inside it is uid 100000 on
# the host. Without this the CI job cannot write the cache it just built.
chown 100000:100000 /nvmepool/nix-cache
chmod 0755 /nvmepool/nix-cache
zfs list nvmepool/nix-cache
```

Confirm the dataset name that comes back — if the pool or dataset name differs from `nvmepool/nix-cache`, use the real one in Step 2 and nowhere else changes.

- [ ] **Step 2: Bind-mount it into the runner LXC**

In `tofu/deployments/edholm/configurations.tfvars`, in the `gitlab-runner` LXC block, add a `mounts` list and a second docker service:

```hcl
      gitlab-runner = {
        memory    = 32768
        cores     = 12
        disk_size = "128G"

        # The signed closures CI publishes. A ZFS dataset rather than rootfs
        # space: it is served to the HTPC over static HTTP and needs its own
        # quota, so a runaway cache cannot fill the runner's disk.
        mounts = [
          { name = "nixcache", dataset = "nvmepool/nix-cache", path = "/srv/nix-cache" },
        ]

        roles = [
          { name = "docker" }
        ]
        docker_services = [
          { name = "gitlab-runner" },
          { name = "nix-cache" }
        ]
      }
```

- [ ] **Step 3: Write the compose bundle**

Create `ansible/roles/docker/templates/nix-cache.yaml.j2`:

```yaml
---
# Static HTTP in front of the file:// binary cache CI writes with
# `nix copy --to file:///srv/nix-cache`. That layout is already a valid cache
# -- nix-cache-info, <hash>.narinfo and nar/*.nar.xz -- so the serving host
# needs no Nix and no daemon of its own, only a web server.
#
# Read-only on purpose: only the CI job writes here, and it writes through the
# bind mount, not through this container.
services:
  nix-cache:
    image: nginx:alpine
    container_name: nix-cache
    volumes:
      - "{{ service_mounts.nixcache }}:/usr/share/nginx/html:ro"
    ports:
      - 8088:80 # caddy:expose
    restart: unless-stopped
```

- [ ] **Step 4: Validate the tofu side, including the new exposed service**

Run: `just validate-tofu`
Expected: `Success!` for both deployments.

Run: `cd tofu/deployments/edholm && tofu plan -var-file=configurations.tfvars`
Expected: adds `module.opnsense_networking.opnsense_dnsmasq_host.service["nix-cache"]` and updates the Caddy drop-in. If `service-registry` errors about an orphaned marker, the `# caddy:expose` comment is not on a published-port line under a compose service key — it must sit on the `- 8088:80` line.

- [ ] **Step 5: Apply and converge**

```bash
just apply-tofu edholm
just setup gitlab-runner
```

Expected: tofu adds the DNS record and reloads Caddy; the Ansible run restarts the container stack and reports the new `nix-cache` service.

- [ ] **Step 6: Verify the mount landed inside the container**

```bash
ssh default-user@gitlab-runner.edholm.cc 'ls -ld /srv/nix-cache && touch /srv/nix-cache/.write-test && rm /srv/nix-cache/.write-test && echo writable'
```

Expected: the directory exists and `writable`. A permission error here means the `chown 100000:100000` in Step 1 was not applied — that is exactly the `/appdata` unmapped-uid failure mode, and the fix is on the host, not in the container.

- [ ] **Step 7: Verify it serves over HTTPS**

```bash
printf 'StoreDir: /nix/store\nWantMassQuery: 0\nPriority: 40\n' | \
  ssh default-user@gitlab-runner.edholm.cc 'cat > /srv/nix-cache/nix-cache-info'
curl -fsS https://nix-cache.edholm.cc/nix-cache-info
```

Expected: the three lines back. (`nix copy --to file://` writes this file itself; creating it early just proves the route works.)

- [ ] **Step 8: Verify the HTPC can reach it**

Run: `ssh default-user@htpc.edholm.cc 'curl -fsS https://nix-cache.edholm.cc/nix-cache-info'`
Expected: the same three lines. If this fails while the laptop succeeds, it is the split-horizon problem — the name must resolve to Caddy on the LAN, not to the WAN address.

- [ ] **Step 9: Commit**

```bash
git add ansible/roles/docker/templates/nix-cache.yaml.j2 \
        tofu/deployments/edholm/configurations.tfvars
git commit -m "feat(docker): serve the Nix binary cache over static HTTP

nix copy --to file:// already produces a valid cache, so the serving host
needs neither Nix nor a daemon -- nginx over a read-only bind mount is
the whole implementation. The dataset gets its own quota so a cache
nobody pruned cannot fill the runner's 128G rootfs.

The caddy:expose marker means the DNS record and the Caddy route come
from the same declaration as everything else, so nix-cache.edholm.cc
needs no hand-written firewall config.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: A Nix-capable runner with a persistent `/nix`

**Files:**
- Modify: `ansible/roles/docker/templates/gitlab-runner.yaml.j2`
- Modify: `ansible/roles/docker/tasks/additional/gitlab-runner.yaml`

**Interfaces:**
- Produces: a second runner registration described `nix-runner`, docker executor, image `nixos/nix`, tagged `nix` — the tag Task 13's jobs select on; a `nix-store` docker volume mounted at `/nix` inside every job container; `/srv/nix-cache` bind-mounted into every job container.
- Consumes: `/srv/nix-cache` on the LXC (Task 10).

The existing registration uses `--executor shell` (despite the compose file's comment claiming docker), and the `vagrant-runner` depends on nothing here. Leave it alone: add a *second* registration rather than changing the one that already works.

Without a persistent `/nix`, every pipeline rebuilds Rust and WASM from zero — that is the single change that makes this workable.

- [ ] **Step 1: Give the runner container the cache path**

In `ansible/roles/docker/templates/gitlab-runner.yaml.j2`, replace the file with:

```yaml
---
# Docker executor: runner spawns sibling containers on the LXC's Docker daemon.
# The LXC is unprivileged on Proxmox (user namespace remapping), so even a full
# LXC escape only lands an attacker as an unprivileged user on the workstation.
#
# /srv/nix-cache is bind-mounted here as well as into the job containers,
# because the runner resolves a job's bind-mount source on *this* container's
# filesystem before handing it to the daemon.
services:
  gitlab-runner:
    image: gitlab/gitlab-runner:latest
    container_name: gitlab-runner
    restart: always
    volumes:
      - runner-config:/etc/gitlab-runner
      - /var/run/docker.sock:/var/run/docker.sock
      - "{{ service_mounts.nixcache }}:/srv/nix-cache"

volumes:
  runner-config:
  # Survives job containers, so a pipeline does not rebuild Rust and WASM from
  # zero every time. Named, not a bind mount: only Nix ever reads it, and it
  # must not be pruned by the cache-prune timer (which filters on the
  # gitlab-runner managed label).
  nix-store:
```

- [ ] **Step 2: Register the Nix runner alongside the existing one**

In `ansible/roles/docker/tasks/additional/gitlab-runner.yaml`, after the existing `Register gitlab-runner` task and before `Deploy gitlab-runner cache prune service`, add:

```yaml
    - name: Check if the Nix runner is already registered
      shell: |
        set -o pipefail
        docker exec gitlab-runner gitlab-runner list 2>&1 | grep -q 'nix-runner'
      args:
        executable: /bin/bash
      register: nix_runner_registered
      failed_when: false
      changed_when: false

    # A second registration rather than a change to the first: the shell
    # executor above still serves everything that is not a Nix build, and
    # re-registering it would invalidate a runner that works.
    #
    # The persistent /nix volume is the point. Without it every pipeline
    # rebuilds Rust and WASM from zero, which turns a two-minute deploy into
    # a forty-minute one.
    - name: Register the Nix runner
      shell: |
        set -o pipefail
        docker exec gitlab-runner gitlab-runner register \
          --non-interactive \
          --url "{{ gitlab_url }}" \
          --token "{{ nix_runner_token }}" \
          --executor docker \
          --description "nix-runner" \
          --docker-image "nixos/nix:latest" \
          --docker-volumes "nix-store:/nix" \
          --docker-volumes "/srv/nix-cache:/srv/nix-cache" \
          --docker-pull-policy "if-not-present"
      args:
        executable: /bin/bash
      when: nix_runner_registered.rc != 0
      changed_when: true
```

and add the token lookup to the block's `vars`, next to the existing `runner_token`:

```yaml
    nix_runner_token: "{{ lookup('community.general.onepassword', 'Gitlab Runner Nix', vault='Private', field='token') }}"
```

- [ ] **Step 3: Create the runner token** **(human)**

In `gitlab.com/yarcod` → Group → Settings → CI/CD → Runners → **New group runner**: tag `nix`, un-tick "Run untagged jobs", description `nix-runner`. Registering at group level is what makes one runner visible to both projects.

Store the token: `op item create --category "API Credential" --title "Gitlab Runner Nix" --vault Private "token[password]=glrt-…"`.

- [ ] **Step 4: Converge**

Run: `just setup gitlab-runner`
Expected: the compose stack is recreated and `Register the Nix runner` reports `changed`.

- [ ] **Step 5: Verify both runners are registered and the volume exists**

```bash
ssh default-user@gitlab-runner.edholm.cc 'docker exec gitlab-runner gitlab-runner list 2>&1'
ssh default-user@gitlab-runner.edholm.cc 'docker volume ls | grep nix-store'
```

Expected: both `workstation-runner` and `nix-runner` listed; a `nix-store` volume present.

- [ ] **Step 6: Verify a Nix job container really persists `/nix` and sees the cache**

```bash
ssh default-user@gitlab-runner.edholm.cc \
  'docker run --rm -v nix-store:/nix -v /srv/nix-cache:/srv/nix-cache nixos/nix:latest \
     sh -c "nix --extra-experimental-features \"nix-command flakes\" build --no-link nixpkgs#hello && ls /srv/nix-cache"'
```

Run it **twice**. Expected: the first run downloads; the second is near-instant (the store persisted), and both list the cache directory's contents.

- [ ] **Step 7: Verify the prune timer will not eat the Nix store**

Run: `ssh default-user@gitlab-runner.edholm.cc 'grep -n volumes /etc/systemd/system/gitlab-runner-cache-prune.service'`
Expected: the prune command carries `--filter label=com.gitlab.gitlab-runner.managed=true`. The `nix-store` volume is created by compose, not by the runner, so it carries no such label and is not pruned. If that filter is missing, **stop** — pruning would delete the persistent store on a schedule.

- [ ] **Step 8: Commit**

```bash
git add ansible/roles/docker/templates/gitlab-runner.yaml.j2 \
        ansible/roles/docker/tasks/additional/gitlab-runner.yaml
git commit -m "feat(gitlab-runner): a Nix-capable runner with a persistent store

Builds for the HTPC have to happen on the LAN to reach the box, so they
happen here. The persistent /nix docker volume is the part that matters:
without it every pipeline rebuilds Rust and WASM from zero, turning a
two-minute deploy into a forty-minute one.

This is a second registration, not a change to the first. The existing
workstation-runner uses the shell executor and still serves everything
that is not a Nix build; re-registering it would invalidate a runner
that works. The new one is tagged 'nix' and does not take untagged jobs.

/srv/nix-cache is bind-mounted into the runner container as well as into
each job container, because the runner resolves a job's bind-mount source
on its own filesystem before handing it to the daemon.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: `ship.sh`, cache pruning, and `just deploy`

**Files:**
- Create: `scripts/ship.sh`
- Create: `scripts/prune-cache.sh`
- Modify: `justfile`

**Interfaces:**
- Consumes: `nixosConfigurations.<machine>` (Task 2); `hosts.<machine>.mac` in tfvars (Task 5); `/srv/nix-cache` (Task 10); `sudo htpc-stage <path>` on the box (Task 14 — until then `ship.sh` stops after `nix copy`, which is exactly the "still activated by hand" end-state of phase 3).
- Produces: `scripts/ship.sh <machine> [--bump]` — the single implementation behind both `just deploy <machine>` and the CI deploy job; `/srv/nix-cache/pointers/<machine>` and `…/<machine>.history`.

- [ ] **Step 1: Write `scripts/ship.sh`**

```bash
#!/usr/bin/env bash
# Build, sign, publish and -- if the box answers -- push one machine's system
# closure.
#
# One implementation with two entry points: `just deploy <machine>` from the
# laptop and the deploy job in .gitlab-ci.yml. CI ships bytes and writes a
# pointer; it never activates. The box verifies signatures and decides when to
# switch, so a stolen deploy key uploads something the box refuses rather than
# granting root.
#
# A sleeping television must never turn a pipeline red: everything after the
# pointer is written is best-effort, and the cache plus the pointer are the
# durable artifact.
set -euo pipefail

MACHINE="${1:?usage: ship.sh <machine> [--bump]}"
shift

BUMP=0
for arg in "$@"; do
  case "$arg" in
    --bump) BUMP=1 ;;
    *) echo "ship.sh: unknown argument '$arg'" >&2; exit 2 ;;
  esac
done

CACHE_DIR="${NIX_CACHE_DIR:-/srv/nix-cache}"
SIGNING_KEY_FILE="${SIGNING_KEY_FILE:-}"
DEPLOY_HOST="${DEPLOY_HOST:-deploy@${MACHINE}.edholm.cc}"
WOL_BROADCAST="${WOL_BROADCAST:-192.168.1.255}"
SSH_WAIT_SECONDS="${SSH_WAIT_SECONDS:-90}"
MIN_FREE_MB="${MIN_FREE_MB:-20480}"
TFVARS="${TFVARS:-tofu/deployments/edholm/configurations.tfvars}"

log() { printf '==> %s\n' "$*"; }

if [ "$BUMP" -eq 1 ]; then
  # This commit is the gate made concrete: every system that ever ran
  # corresponds to a terranse commit that can be checked out and rebuilt.
  log "bumping the home-player input"
  nix flake update home-player
  if git diff --quiet -- flake.lock; then
    log "flake.lock unchanged"
  else
    git add flake.lock
    # [skip ci] because the lock bump and the deploy are one job; without it
    # the push would re-trigger the pipeline that made it.
    git -c user.name="terranse CI" -c user.email="ci@edholm.cc" \
      commit -m "chore(nix): bump home-player [skip ci]"
    if [ -n "${PUSH_REMOTE:-}" ]; then
      git push "$PUSH_REMOTE" "HEAD:${PUSH_BRANCH:-main}"
    else
      log "no PUSH_REMOTE set; leaving the bump commit local"
    fi
  fi
fi

log "building ${MACHINE}"
OUT=$(nix build --no-link --print-out-paths \
  ".#nixosConfigurations.${MACHINE}.config.system.build.toplevel")
log "built ${OUT}"

# A `nix copy` into a full dataset leaves a half-written cache that later
# fetches trip over, so refuse before rather than after.
avail=$(df -Pm "$CACHE_DIR" | awk 'NR==2 {print $4}')
if [ "$avail" -lt "$MIN_FREE_MB" ]; then
  echo "ship.sh: only ${avail}MB free on ${CACHE_DIR}, need ${MIN_FREE_MB}MB" >&2
  exit 1
fi

if [ -n "$SIGNING_KEY_FILE" ]; then
  log "signing with ${SIGNING_KEY_FILE}"
  nix store sign --recursive --key-file "$SIGNING_KEY_FILE" "$OUT"
else
  log "no SIGNING_KEY_FILE; publishing unsigned (the box will refuse this)"
fi

log "publishing to ${CACHE_DIR}"
nix copy --to "file://${CACHE_DIR}" "$OUT"

install -d "${CACHE_DIR}/pointers"
# Written last and atomically: a pointer must never name a closure the cache
# does not fully hold.
printf '%s\n' "$OUT" > "${CACHE_DIR}/pointers/${MACHINE}.new"
mv "${CACHE_DIR}/pointers/${MACHINE}.new" "${CACHE_DIR}/pointers/${MACHINE}"
printf '%s\n' "$OUT" >> "${CACHE_DIR}/pointers/${MACHINE}.history"
log "pointer written"

"$(dirname "$0")/prune-cache.sh" || log "cache prune failed (non-fatal)"

# ---- best-effort from here on --------------------------------------------

# The MAC is declared once, in tfvars, and read by both the DHCP reservation
# and this step.
WOL_MAC="${WOL_MAC:-$(awk -v m="$MACHINE" '
  $1 == m && $2 == "=" { inblock = 1 }
  inblock && $1 == "mac" { gsub(/"/, "", $3); print $3; exit }
' "$TFVARS" 2>/dev/null || true)}"

if [ -n "$WOL_MAC" ] && command -v wakeonlan >/dev/null 2>&1; then
  log "waking ${WOL_MAC}"
  wakeonlan -i "$WOL_BROADCAST" "$WOL_MAC" || true
else
  log "no MAC for ${MACHINE} (or no wakeonlan); not waking"
fi

log "waiting up to ${SSH_WAIT_SECONDS}s for ${DEPLOY_HOST}"
deadline=$(( $(date +%s) + SSH_WAIT_SECONDS ))
reachable=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
       "$DEPLOY_HOST" true 2>/dev/null; then
    reachable=1
    break
  fi
  sleep 5
done

if [ "$reachable" -ne 1 ]; then
  log "${DEPLOY_HOST} did not answer; it will pull from the cache on next boot"
  exit 0
fi

log "pushing the closure"
nix copy --to "ssh-ng://${DEPLOY_HOST}" "$OUT"

if ssh -o BatchMode=yes "$DEPLOY_HOST" 'test -x /run/current-system/sw/bin/htpc-stage'; then
  log "staging"
  ssh -o BatchMode=yes "$DEPLOY_HOST" \
    "sudo /run/current-system/sw/bin/htpc-stage $OUT"
else
  log "htpc-stage is not installed on ${MACHINE} yet; closure pushed, activate by hand"
fi

log "done"
```

Then: `chmod +x scripts/ship.sh`.

- [ ] **Step 2: Write `scripts/prune-cache.sh`**

```bash
#!/usr/bin/env bash
# Prune the file:// binary cache. `nix store gc` does not apply to it, so
# without this it grows by a full system closure on every deploy.
#
# Reachability is computed from the cache's own narinfo files rather than from
# the local Nix store: an older pointer's closure may well have been collected
# locally, and it must still survive here as long as it is one of the last N.
set -euo pipefail

CACHE_DIR="${NIX_CACHE_DIR:-/srv/nix-cache}"
KEEP="${CACHE_KEEP:-5}"

cd "$CACHE_DIR"
shopt -s nullglob

queue=$(mktemp)
seen=$(mktemp)
kept_nars=$(mktemp)
trap 'rm -f "$queue" "$seen" "$kept_nars"' EXIT

# Seed: the store-path hashes named by the last N pointers of every machine.
for history in pointers/*.history; do
  tail -n "$KEEP" "$history" | sed 's|^/nix/store/||; s|-.*$||'
done | sort -u > "$queue"

if [ ! -s "$queue" ]; then
  echo "prune-cache: no pointer history; nothing to do"
  exit 0
fi

# Breadth-first over References:, straight out of the narinfos.
while [ -s "$queue" ]; do
  h=$(head -n1 "$queue")
  sed -i 1d "$queue"
  # An `if`, not `grep … && continue`: under `set -e` a failing grep at the
  # head of an && chain takes the whole script down.
  if grep -qxF "$h" "$seen" 2>/dev/null; then
    continue
  fi
  printf '%s\n' "$h" >> "$seen"
  [ -f "$h.narinfo" ] || continue
  awk '/^References: /{ for (i = 2; i <= NF; i++) print $i }' "$h.narinfo" \
    | sed 's|-.*$||' >> "$queue"
done
sort -u "$seen" -o "$seen"

removed=0
for f in *.narinfo; do
  h="${f%.narinfo}"
  if grep -qxF "$h" "$seen"; then
    awk '/^URL: /{ print $2 }' "$f" >> "$kept_nars"
  else
    rm -f "$f"
    removed=$((removed + 1))
  fi
done
sort -u "$kept_nars" -o "$kept_nars"

nars_removed=0
while IFS= read -r n; do
  grep -qxF "$n" "$kept_nars" || { rm -f "$n"; nars_removed=$((nars_removed + 1)); }
done < <(find nar -type f 2>/dev/null)

# Keep the history files themselves from growing without bound.
for history in pointers/*.history; do
  tail -n $((KEEP * 4)) "$history" > "$history.tmp" && mv "$history.tmp" "$history"
done

echo "prune-cache: kept $(wc -l < "$seen") paths, removed ${removed} narinfo and ${nars_removed} nar files"
```

Then: `chmod +x scripts/prune-cache.sh`.

- [ ] **Step 3: Add the `deploy` recipe**

In `justfile`, next to the `secrets` recipe added in Task 8:

```just
# Build, sign, publish and push a NixOS machine's system closure. Same script
# CI runs, so there is one implementation with two entry points.
deploy machine:
    ./scripts/ship.sh {{ machine }}
```

- [ ] **Step 4: Verify `prune-cache.sh` is safe on an empty cache**

Run: `NIX_CACHE_DIR=$(mktemp -d) ./scripts/prune-cache.sh`
Expected: `prune-cache: no pointer history; nothing to do`, exit 0.

- [ ] **Step 5: Verify `ship.sh` builds and publishes from the laptop**

The laptop cannot write `/srv/nix-cache`, so point it at a scratch directory and skip signing:

```bash
export NIX_CACHE_DIR=$(mktemp -d)
export SSH_WAIT_SECONDS=10
./scripts/ship.sh htpc
ls "$NIX_CACHE_DIR"
cat "$NIX_CACHE_DIR/pointers/htpc"
```

Expected: `nix-cache-info`, many `*.narinfo`, a `nar/` directory, and `pointers/htpc` holding a `/nix/store/…-nixos-system-htpc-…` path. The run logs `no SIGNING_KEY_FILE` and either reaches the box or reports it did not answer — **both are success**.

- [ ] **Step 6: Verify the MAC really came out of tfvars**

Run: `./scripts/ship.sh htpc 2>&1 | grep -E 'waking|not waking'`
Expected: `waking <the MAC from Task 3 Step 5>` (or `no MAC … (or no wakeonlan)` if `wakeonlan` is not installed locally — install it with `nix shell nixpkgs#wakeonlan` and re-run to confirm the MAC is found).

- [ ] **Step 7: Verify pruning keeps a live closure and drops a dead one**

```bash
export NIX_CACHE_DIR=$(mktemp -d)
./scripts/ship.sh htpc                       # closure A
echo '/nix/store/0000000000000000000000000000000-fake' >> "$NIX_CACHE_DIR/pointers/htpc.history"
CACHE_KEEP=1 ./scripts/prune-cache.sh
curl -sf "file://$NIX_CACHE_DIR/nix-cache-info" >/dev/null || ls "$NIX_CACHE_DIR" >/dev/null
ls "$NIX_CACHE_DIR"/*.narinfo | wc -l
```

Expected: with `CACHE_KEEP=1` the only kept pointer is the fake one, which resolves to nothing, so the narinfo count drops to `0`. Re-run `./scripts/ship.sh htpc` afterwards and confirm the count is large again — that proves prune removes, and publish restores.

- [ ] **Step 8: Commit**

```bash
git add scripts/ship.sh scripts/prune-cache.sh justfile
git commit -m "feat(nix): one shipping path for laptop and CI

ship.sh builds, signs, publishes to the file:// cache and writes the
pointer, then tries to wake the box and push. Everything after the
pointer is best-effort on purpose: a sleeping television must never turn
a pipeline red, and the cache plus the pointer are the durable artifact
the box picks up on its next boot.

The pointer is written atomically and last, so it can never name a
closure the cache does not fully hold, and the machine's MAC is read
from the same tfvars declaration the DHCP reservation uses -- one
declaration, two consumers.

prune-cache.sh exists because nix store gc does not apply to a file://
cache; without it the dataset grows by a full system closure per deploy.
It walks References: out of the cache's own narinfos rather than the
local store, because an older pointer's closure may well have been
collected locally and must still survive here.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 13: The two pipelines

**Files:**
- Create: `.gitlab-ci.yml` (terranse)
- Create: `/home/daniele/Repos/home-player/.gitlab-ci.yml`

**Interfaces:**
- Consumes: the `nix`-tagged runner (Task 11); `DEPLOY_SSH_KEY`, `CACHE_SIGNING_KEY`, `CI_PUSH_TOKEN`, `KNOWN_HOSTS` on terranse and `TERRANSE_TRIGGER_TOKEN` on home-player (Task 6); `scripts/ship.sh` (Task 12).
- Produces: on a push to home-player master, a signed closure in the cache and a pointer, with the box updated if it was awake.

- [ ] **Step 1: Write terranse's pipeline**

Create `.gitlab-ci.yml` at the terranse repo root:

```yaml
---
stages:
  - check
  - deploy

# Full history: the deploy job commits the flake.lock bump and pushes it back.
variables:
  GIT_DEPTH: "0"

.nix:
  image: nixos/nix:latest
  tags:
    - nix
  before_script:
    - printf 'experimental-features = nix-command flakes\n' >> /etc/nix/nix.conf
    - mkdir -p ~/.ssh && chmod 700 ~/.ssh
    # base64 because a masked CI variable cannot hold a multi-line PEM.
    - printf '%s' "$DEPLOY_SSH_KEY" | base64 -d > ~/.ssh/id_ed25519
    - chmod 600 ~/.ssh/id_ed25519
    # Without known_hosts the git+ssh flake input and the closure push both
    # hang on host-key confirmation in a container with no TTY.
    - printf '%s\n' "$KNOWN_HOSTS" > ~/.ssh/known_hosts
    - chmod 600 ~/.ssh/known_hosts

flake-check:
  extends: .nix
  stage: check
  script:
    - nix flake check -L

# ONE job on purpose. Splitting the lock bump from the build would let the
# bump's own push re-trigger CI, and would let two pushes interleave a bump
# from one with a build from the other. resource_group serialises concurrent
# runs; [skip ci] on the bump commit (see ship.sh) closes the loop.
deploy-htpc:
  extends: .nix
  stage: deploy
  resource_group: htpc-deploy
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
  variables:
    NIX_CACHE_DIR: /srv/nix-cache
    SIGNING_KEY_FILE: /run/htpc-cache-key
    PUSH_BRANCH: $CI_DEFAULT_BRANCH
  script:
    - printf '%s' "$CACHE_SIGNING_KEY" > "$SIGNING_KEY_FILE"
    - chmod 600 "$SIGNING_KEY_FILE"
    - export PUSH_REMOTE="https://oauth2:${CI_PUSH_TOKEN}@gitlab.com/${CI_PROJECT_PATH}.git"
    - nix shell nixpkgs#bash nixpkgs#git nixpkgs#openssh nixpkgs#wakeonlan nixpkgs#gawk
        -c ./scripts/ship.sh htpc --bump
  after_script:
    - rm -f /run/htpc-cache-key
```

- [ ] **Step 2: Write home-player's pipeline**

Create `/home/daniele/Repos/home-player/.gitlab-ci.yml`:

```yaml
---
stages:
  - check
  - trigger

check:
  image: nixos/nix:latest
  tags:
    - nix
  stage: check
  before_script:
    - printf 'experimental-features = nix-command flakes\n' >> /etc/nix/nix.conf
  script:
    - nix flake check -L
    - nix build -L .#backend .#web .#shell

# Deliberately no `strategy: depend`. terranse's deploy job succeeds even when
# the television is asleep, so waiting on it would only couple two pipelines
# without telling us anything new.
trigger-terranse:
  stage: trigger
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
  trigger:
    project: yarcod/terranse
    branch: main
```

- [ ] **Step 3: Verify home-player's check job passes**

```bash
cd /home/daniele/Repos/home-player
git add .gitlab-ci.yml
git commit -m "ci: build and check on every push to master

The HTPC's pipeline consumes this repo as a flake input, so a red build
here must stop the bump there rather than reach the television.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
git push
```

Watch the pipeline. Expected: `check` green. The first run is slow (Rust + WASM from scratch); the second should be minutes, which is the persistent `/nix` volume proving itself.

- [ ] **Step 4: Verify terranse's flake-check job passes**

```bash
cd /home/daniele/Repos/terranse
git add .gitlab-ci.yml
git commit -m "ci: check every machine and ship the HTPC's closure

nix flake check builds every machine's toplevel, so a broken role fails
here instead of on the television. The deploy job is deliberately one
job: splitting the flake.lock bump from the build would let the bump's
own push re-trigger CI, and would let two concurrent pushes interleave a
bump from one run with a build from another. resource_group serialises
what is left.

CI signs and writes a pointer; it never activates. A stolen deploy key
uploads bytes the box refuses rather than granting root.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
git push
```

Expected: `flake-check` green. If it fails on the `home-player` input with `Host key verification failed` or `Permission denied (publickey)`, the `KNOWN_HOSTS` or deploy-key setup from Task 6 is wrong — fix that, not the pipeline.

- [ ] **Step 5: Verify the deploy job publishes a signed closure**

Watch the `deploy-htpc` job on the same pipeline. Expected in the log: `built /nix/store/…`, `signing with /run/htpc-cache-key`, `publishing to /srv/nix-cache`, `pointer written`, then either a successful push or `did not answer`. Either way the job is **green**.

Then, from the laptop:

```bash
curl -fsS https://nix-cache.edholm.cc/pointers/htpc
```

Expected: the same store path the job logged.

- [ ] **Step 6: Verify the closure really is signed by the builder key**

```bash
STORE_PATH=$(curl -fsS https://nix-cache.edholm.cc/pointers/htpc)
HASH=$(basename "$STORE_PATH" | cut -d- -f1)
curl -fsS "https://nix-cache.edholm.cc/${HASH}.narinfo" | grep '^Sig:'
```

Expected: a `Sig: htpc-cache-1:…` line. If it says only `cache.nixos.org-1`, the signing step did not run against the toplevel.

- [ ] **Step 7: Verify the end-to-end trigger**

Push a trivial commit to home-player master (e.g. a README typo fix). Expected: home-player's pipeline goes green, terranse's pipeline starts, `deploy-htpc` bumps `flake.lock` with a `[skip ci]` commit, publishes, and does **not** start a third pipeline.

Run: `cd /home/daniele/Repos/terranse && git pull && git log --oneline -2`
Expected: a `chore(nix): bump home-player [skip ci]` commit on top.

**This is the end of phase 3**: a push builds and publishes a signed closure, still activated by hand.

---

## Task 14: The `staged-updates` role

**Files:**
- Create: `nix/roles/staged-updates.nix`
- Modify: `nix/roles/default.nix`
- Modify: `nix/machines.nix`

**Interfaces:**
- Consumes: `nix.settings.trusted-public-keys` and the `deploy` user (the shared `base` role, keyed in Task 2); the backend on `127.0.0.1:9600` (Task 7); the `tv` user's `home-player-shell.service` (Task 9); `https://nix-cache.edholm.cc/pointers/htpc` (Tasks 10 and 13).
- Produces: `roles.staged-updates.{enable,cacheUrl,deployUser,kioskUser,requireSignatures,requireKioskUnit,healthUrl,watchdogSeconds}`; the commands `htpc-stage <path>` (what `ship.sh` calls over sudo) and `htpc-update [--force-idle]`; the units `htpc-update.{service,timer}`, `htpc-update-apply.service`, `htpc-update-watchdog.service`, `htpc-update-fetch.service`; `/var/lib/htpc-update/state.json` — **the popup contract home-player's side reads**.

The `state.json` contract, fixed here and implemented on home-player's side later:

```json
{
  "reason": "none | busy | bad | rebooting | rolled-back",
  "pending": "/nix/store/…-nixos-system-htpc-…",
  "current": "/nix/store/…-nixos-system-htpc-…",
  "reboot_required": true,
  "staged_at": 1789000000,
  "age_seconds": 3600
}
```

- [ ] **Step 1: Write the role**

Create `nix/roles/staged-updates.nix`:

```nix
# The receiver and the activation policy.
#
# The box does not accept "an update". It accepts one specific store path,
# signed by a key it already trusts, recorded as a generation it can roll back
# from, and activated by its own root-owned policy at a moment it chose. CI
# ships bytes and writes a pointer; trust is enforced here, by the box.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.roles.staged-updates;

  stateDir = "/var/lib/htpc-update";
  pendingRoot = "/nix/var/nix/gcroots/htpc-pending";
  badRevisions = "${stateDir}/bad-revisions";
  stagedAt = "${stateDir}/staged-at";
  # Written just before an activation, cleared once the result is proved
  # healthy. Its presence on a fresh boot is how a kernel update gets
  # watchdogged at all -- nothing can poll across a reboot.
  verifyMarker = "${stateDir}/verify-after-reboot";

  systemProfile = "/nix/var/nix/profiles/system";

  # Shared between the policy engine and the watchdog, so state.json has
  # exactly one writer shape.
  writeStateFn = ''
    write_state() {
      local reason="$1" pending="$2" reboot="$3"
      local staged age
      staged=$(cat ${stagedAt} 2>/dev/null || echo 0)
      age=$(( $(date -u +%s) - staged ))
      jq -n \
        --arg reason "$reason" \
        --arg pending "$pending" \
        --arg current "$(readlink -f /run/current-system)" \
        --argjson reboot_required "$reboot" \
        --argjson staged_at "$staged" \
        --argjson age_seconds "$age" \
        '{ reason: $reason, pending: $pending, current: $current,
           reboot_required: ($reboot_required == 1),
           staged_at: $staged_at, age_seconds: $age_seconds }' \
        > ${stateDir}/state.json.new
      mv ${stateDir}/state.json.new ${stateDir}/state.json
    }
  '';

  htpc-update-watchdog = pkgs.writeShellApplication {
    name = "htpc-update-watchdog";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      gnugrep
      jq
      nix
      systemd
    ];
    text = ''
      ${writeStateFn}

      [ -f ${verifyMarker} ] || exit 0
      pending=$(cat ${verifyMarker})

      healthy=0
      deadline=$(( $(date +%s) + ${toString cfg.watchdogSeconds} ))
      while [ "$(date +%s)" -lt "$deadline" ]; do
        if curl -fsS --max-time 5 ${cfg.healthUrl}/health >/dev/null 2>&1; then
          ${lib.optionalString cfg.requireKioskUnit ''
            # A backend answering /health while the screen renders nothing is
            # the failure this narrows. It does not close it.
            if ! systemctl --user --machine=${cfg.kioskUser}@.host \
                 is-active --quiet home-player-shell.service; then
              sleep 5
              continue
            fi
          ''}
          healthy=1
          break
        fi
        sleep 5
      done

      if [ "$healthy" -eq 1 ]; then
        rm -f ${verifyMarker}
        echo "htpc-update-watchdog: $pending is healthy"
        write_state none "$pending" 0
        exit 0
      fi

      echo "htpc-update-watchdog: $pending never became healthy; rolling back" >&2

      # Barred by exact path, and only this path. A later, different revision
      # is unaffected -- otherwise the 15-minute timer would rollback-loop on
      # the same closure forever.
      printf '%s\n' "$pending" >> ${badRevisions}
      rm -f ${pendingRoot} ${verifyMarker}

      nix-env -p ${systemProfile} --rollback
      restored=$(readlink -f ${systemProfile})
      booted=$(readlink -f /run/booted-system)
      write_state rolled-back "$pending" 0

      if [ "$(readlink -f "$restored/kernel")" != "$(readlink -f "$booted/kernel")" ]; then
        "$restored/bin/switch-to-configuration" boot
        systemctl reboot
      else
        "$restored/bin/switch-to-configuration" switch
      fi
      exit 1
    '';
  };

  htpc-update = pkgs.writeShellApplication {
    name = "htpc-update";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      gnugrep
      jq
      nix
      systemd
    ];
    text = ''
      ${writeStateFn}

      # An `if`, not `[ … ] && force_idle=1`: writeShellApplication sets
      # `set -e`, under which a bare test-and-assign line exits the script the
      # moment the test is false.
      force_idle=0
      if [ "''${1:-}" = "--force-idle" ]; then
        force_idle=1
      fi

      install -d -m 0755 ${stateDir}
      touch ${badRevisions}

      if [ ! -L ${pendingRoot} ]; then
        write_state none "" 0
        exit 0
      fi
      pending=$(readlink -f ${pendingRoot})
      current=$(readlink -f /run/current-system)

      if [ "$pending" = "$current" ]; then
        write_state none "$pending" 0
        exit 0
      fi

      if grep -qxF "$pending" ${badRevisions}; then
        echo "htpc-update: $pending is a known-bad revision; not activating" >&2
        write_state bad "$pending" 0
        exit 0
      fi

      # A changed kernel or initrd cannot be switched into a running system;
      # it has to be written to the boot loader and rebooted into.
      reboot_required=0
      if [ "$(readlink -f "$pending/kernel")" != "$(readlink -f /run/booted-system/kernel)" ] ||
         [ "$(readlink -f "$pending/initrd")" != "$(readlink -f /run/booted-system/initrd)" ]; then
        reboot_required=1
      fi

      busy=false
      if [ "$force_idle" -eq 0 ]; then
        # /system/activity is home-player's side of the contract and may not
        # exist yet. A failed request reads as idle, so the loop works before
        # the popup lands.
        busy=$(curl -fsS --max-time 5 ${cfg.healthUrl}/system/activity 2>/dev/null \
               | jq -r '.busy' 2>/dev/null || echo false)
      fi

      if [ "$busy" = "true" ]; then
        # Change nothing. The timer re-checks, so the update also lands on its
        # own the moment playback ends, whether or not the popup is ever shown
        # or accepted.
        echo "htpc-update: busy; leaving $pending staged"
        write_state busy "$pending" "$reboot_required"
        exit 0
      fi

      echo "htpc-update: activating $pending (reboot_required=$reboot_required)"

      # --set is what creates the generation, and therefore the rollback.
      nix-env -p ${systemProfile} --set "$pending"
      printf '%s\n' "$pending" > ${verifyMarker}

      if [ "$reboot_required" -eq 1 ]; then
        "$pending/bin/switch-to-configuration" boot
        write_state rebooting "$pending" 1
        # The watchdog cannot poll across a reboot, so it runs on the way back
        # and finds the marker written above.
        systemctl reboot
        exit 0
      fi

      "$pending/bin/switch-to-configuration" switch
      exec ${lib.getExe htpc-update-watchdog}
    '';
  };

  htpc-stage = pkgs.writeShellApplication {
    name = "htpc-stage";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      nix
      systemd
    ];
    text = ''
      activate=1
      if [ "''${1:-}" = "--no-activate" ]; then
        activate=0
        shift
      fi
      path="''${1:?usage: htpc-stage [--no-activate] <store-path>}"

      if [ ! -e "$path" ]; then
        echo "htpc-stage: $path is not in the store" >&2
        exit 1
      fi

      ${lib.optionalString cfg.requireSignatures ''
        # The first thing this does, before the path becomes reachable from a
        # GC root. A stolen deploy key can upload bytes; it cannot make the
        # box run them.
        nix store verify --recursive --sigs-needed 1 "$path"
      ''}

      install -d -m 0755 ${stateDir}
      touch ${badRevisions}
      if grep -qxF "$path" ${badRevisions}; then
        echo "htpc-stage: $path is on the bad-revisions list; refusing" >&2
        exit 1
      fi

      # A GC root, so nix.gc cannot eat the closure between staging and
      # activation.
      ln -sfn "$path" ${pendingRoot}
      date -u +%s > ${stagedAt}
      echo "htpc-stage: staged $path"

      if [ "$activate" -eq 1 ]; then
        systemctl start --no-block htpc-update.service
      fi
    '';
  };
in
{
  options.roles.staged-updates = {
    enable = lib.mkEnableOption "receiving and activating staged system generations";

    cacheUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://nix-cache.edholm.cc";
      description = "Binary cache to pull from when a push did not land.";
    };

    deployUser = lib.mkOption {
      type = lib.types.str;
      default = "deploy";
      description = "Account CI pushes closures to. Gets exactly one sudo entry.";
    };

    kioskUser = lib.mkOption {
      type = lib.types.str;
      default = "tv";
      description = "Account whose home-player-shell user unit the watchdog checks.";
    };

    backendUser = lib.mkOption {
      type = lib.types.str;
      default = "home-player";
      description = "Account allowed, by polkit, to start htpc-update-apply.service.";
    };

    healthUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:9600";
      description = "Backend base URL for /health and /system/activity.";
    };

    watchdogSeconds = lib.mkOption {
      type = lib.types.int;
      default = 120;
      description = "How long a freshly activated generation has to look healthy.";
    };

    requireSignatures = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Verify staged closures against the trusted keys. Only the nixosTest
        turns this off -- a test VM has no builder key, and the thing under
        test is the policy, not the cryptography.
      '';
    };

    requireKioskUnit = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Require the kiosk shell's user unit to be active before calling a
        generation healthy. Off in the nixosTest, which runs no kiosk.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      htpc-stage
      htpc-update
      htpc-update-watchdog
    ];

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0755 root root -"
      "f ${badRevisions} 0644 root root -"
    ];

    # Exactly one command, and its first action is to verify signatures. This
    # is the whole privilege CI has on the box.
    security.sudo.extraRules = [
      {
        users = [ cfg.deployUser ];
        commands = [
          {
            command = "/run/current-system/sw/bin/htpc-stage";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];

    # The backend gets no sudo and no shell; it can request exactly one
    # pre-declared action, which is how "Update ready -- apply now?" works
    # without handing the UI any privilege.
    security.polkit.enable = true;
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            action.lookup("unit") == "htpc-update-apply.service" &&
            action.lookup("verb") == "start" &&
            subject.user == "${cfg.backendUser}") {
          return polkit.Result.YES;
        }
      });
    '';

    systemd.services.htpc-update = {
      description = "Activate a staged system generation when the TV is idle";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe htpc-update;
      };
    };

    systemd.timers.htpc-update = {
      description = "Re-check the staged generation";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10min";
        OnUnitActiveSec = "15min";
        Persistent = true;
      };
    };

    systemd.services.htpc-update-apply = {
      description = "Apply the staged generation now (the viewer accepted the popup)";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe htpc-update} --force-idle";
      };
    };

    systemd.services.htpc-update-watchdog = {
      description = "Verify a freshly activated generation and roll back if it is unhealthy";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "home-player-backend.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe htpc-update-watchdog;
      };
    };

    systemd.services.htpc-update-fetch = {
      description = "Fetch the published system closure from the binary cache";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      # After the watchdog, so a boot that exists to verify a kernel update is
      # not immediately handed a newer closure to stage instead.
      after = [
        "network-online.target"
        "htpc-update-watchdog.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "htpc-update-fetch" ''
          set -euo pipefail
          export PATH=${
            lib.makeBinPath (with pkgs; [
              coreutils
              curl
              nix
            ])
          }:$PATH

          pointer=$(curl -fsS --max-time 20 \
            "${cfg.cacheUrl}/pointers/${config.networking.hostName}" || true)
          if [ -z "$pointer" ]; then
            echo "htpc-update-fetch: no pointer at ${cfg.cacheUrl}"
            exit 0
          fi

          current=$(readlink -f /run/current-system)
          [ "$pointer" != "$current" ] || exit 0
          if [ -L ${pendingRoot} ] && [ "$(readlink -f ${pendingRoot})" = "$pointer" ]; then
            exit 0
          fi

          echo "htpc-update-fetch: fetching $pointer"
          nix copy --from "${cfg.cacheUrl}" "$pointer"

          # Nobody is watching at boot, so this path activates immediately.
          # It is what catches every push where wake-on-LAN did not land.
          ${lib.getExe htpc-stage} --no-activate "$pointer"
          ${lib.getExe htpc-update} --force-idle
        '';
      };
    };
  };
}
```

- [ ] **Step 2: Register and list it**

`nix/roles/default.nix`:

```nix
{
  base = ./base.nix;
  home-player = ./home-player.nix;
  kiosk = ./kiosk.nix;
  staged-updates = ./staged-updates.nix;
  video = ./video.nix;
}
```

`nix/machines.nix`, after `kiosk`:

```nix
      { name = "staged-updates"; }
```

- [ ] **Step 3: Build**

Run: `nix flake check -L`
Expected: no output.

- [ ] **Step 4: Verify the sudo rule is exactly one command**

Run: `nix eval --raw .#nixosConfigurations.htpc.config.security.sudo.extraConfig | grep deploy`
Expected: a single line granting `NOPASSWD` on `/run/current-system/sw/bin/htpc-stage` and nothing else. If `deploy` appears with `ALL`, the rule is wrong — stop.

- [ ] **Step 5: Deploy**

Run: `nixos-rebuild switch --flake .#htpc --target-host default-user@htpc.edholm.cc --sudo`
Expected: the four new units appear and `htpc-update.timer` starts.

- [ ] **Step 6: Verify an unsigned path is refused**

```bash
ssh default-user@htpc.edholm.cc \
  'sudo /run/current-system/sw/bin/htpc-stage $(readlink -f /run/current-system) ; echo "exit=$?"'
```

Expected: this **succeeds** (the running system is signed or locally built) — it proves the happy path. Now the refusal:

```bash
ssh default-user@htpc.edholm.cc \
  'p=$(nix-build --no-out-link -E "with import <nixpkgs> {}; runCommand \"unsigned\" {} \"echo hi > \$out\"" 2>/dev/null || echo /nix/store/nonexistent) ;
   sudo /run/current-system/sw/bin/htpc-stage "$p" ; echo "exit=$?"'
```

Expected: a non-zero exit with a `nix store verify` error, or `is not in the store`. Either way the pending GC root must **not** point at it:

```bash
ssh default-user@htpc.edholm.cc 'readlink -f /nix/var/nix/gcroots/htpc-pending'
```

- [ ] **Step 7: Verify `state.json` exists and has the contract's shape**

```bash
ssh default-user@htpc.edholm.cc 'sudo systemctl start htpc-update.service; sudo cat /var/lib/htpc-update/state.json'
```

Expected: valid JSON with the keys `reason`, `pending`, `current`, `reboot_required`, `staged_at`, `age_seconds`. `reason` will be `none`.

- [ ] **Step 8: Verify the boot-time fetch is wired and harmless**

```bash
ssh default-user@htpc.edholm.cc 'sudo systemctl start htpc-update-fetch.service; sudo journalctl -u htpc-update-fetch -n 10 --no-pager'
```

Expected: either `no pointer at …` or a fetch that ends with the pending path equalling the running system. It must **not** activate anything unexpected — the box is already running what CI published.

- [ ] **Step 9: Commit**

```bash
git add nix/roles/staged-updates.nix nix/roles/default.nix nix/machines.nix
git commit -m "feat(nix): let the HTPC decide when to take an update

Auto-update would defeat the point of NixOS if the box accepted 'an
update'. It does not. It accepts one specific store path, signed by a key
it already trusts, pinned by a flake.lock bump a green pipeline made,
recorded as a generation it can roll back from, and activated by its own
root-owned policy at a moment it chose.

deploy gets exactly one passwordless sudo entry, htpc-stage, whose first
action is nix store verify against the trusted keys -- trust is enforced
on the box, by the box, so a stolen deploy key uploads bytes the box
refuses rather than granting root.

A failed /system/activity request reads as idle on purpose: that
endpoint is home-player's side of the contract and does not exist yet,
and the loop has to work before the popup lands.

A revision that fails the watchdog is barred by exact path and only that
path, so the fifteen-minute timer cannot rollback-loop on it and a later,
different revision is unaffected.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 15: The activation-policy `nixosTest`

**Files:**
- Create: `nix/tests/fake-home-player.py`
- Create: `nix/tests/staged-updates.nix`
- Modify: `flake.nix` (register the check)
- Modify: `.gitlab-ci.yml` (run the VM test only where `/dev/kvm` exists)

**Interfaces:**
- Consumes: `nix/roles/staged-updates.nix` and its `requireSignatures` / `requireKioskUnit` / `watchdogSeconds` escape hatches (Task 14).
- Produces: `checks.x86_64-linux.staged-updates`.

This is the highest-value test in the design: it covers the logic most likely to ruin an evening, and it runs with no hardware. The second generation is a **specialisation** of the node's own configuration — a complete system closure that is already in the VM's store at `/run/current-system/specialisation/next`, which avoids having to build and copy a foreign system into a test VM. The same trick is what `nixpkgs`' own `nixos/tests/switch-test.nix` uses.

- [ ] **Step 1: Write the stand-in backend**

Create `nix/tests/fake-home-player.py`:

```python
"""A stand-in for home-player's backend, driven by two files.

/health and /system/activity are the whole contract the update policy depends
on, and both answers come from /run/fake-backend, so the test flips "busy" or
"unhealthy" with one echo.
"""

import http.server
import json
import pathlib

STATE = pathlib.Path("/run/fake-backend")


def flag(name, default):
    try:
        return (STATE / name).read_text().strip() == "true"
    except OSError:
        return default


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            ok = flag("healthy", True)
            code = 200 if ok else 503
            body = json.dumps({"status": "ok" if ok else "unhealthy"})
        elif self.path == "/system/activity":
            code = 200
            body = json.dumps({"busy": flag("busy", False)})
        else:
            code = 404
            body = "{}"

        payload = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        pass


http.server.HTTPServer(("127.0.0.1", 9600), Handler).serve_forever()
```

- [ ] **Step 2: Write the test**

Create `nix/tests/staged-updates.nix`:

```nix
# Boot a VM, stage a second generation, and assert the three things the policy
# exists to get right: busy means nothing happens, idle means it activates,
# and an unhealthy backend means it rolls back *and* marks the revision bad so
# the timer does not retry it every fifteen minutes.
{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "htpc-staged-updates";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ ../roles/staged-updates.nix ];

      roles.staged-updates = {
        enable = true;
        # A test VM has no builder key, and the thing under test is the
        # policy, not the cryptography -- Task 14 Step 6 covers verification
        # against the real trusted keys on the real box.
        requireSignatures = false;
        # No kiosk in this VM.
        requireKioskUnit = false;
        # The unhealthy case has to actually wait this out.
        watchdogSeconds = 15;
      };

      # switch-to-configuration is optional in current nixpkgs and this test
      # is entirely about calling it.
      system.switch.enable = true;

      systemd.tmpfiles.rules = [
        "d /run/fake-backend 0755 root root -"
        "f /run/fake-backend/busy 0644 root root - false"
        "f /run/fake-backend/healthy 0644 root root - true"
      ];

      systemd.services.fake-home-player = {
        description = "Stand-in for the home-player backend";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${./fake-home-player.py}";
      };

      # The second generation. A specialisation is a full system closure built
      # alongside the parent and reachable at
      # /run/current-system/specialisation/next, so nothing has to be copied
      # into the VM. The kernel and initrd are identical to the parent's, which
      # is what puts this on the `switch` path rather than the `boot` one.
      specialisation.next.configuration = {
        environment.etc."htpc-generation".text = "2";
      };
    };

  testScript = ''
    import json

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_open_port(9600)

    base = machine.succeed("readlink -f /run/current-system").strip()
    nxt = machine.succeed("readlink -f /run/current-system/specialisation/next").strip()

    # A test VM boots straight from a store path, so the system profile has no
    # generations at all -- and with no generation 1 there is nothing to roll
    # back to.
    machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {base}")

    with subtest("busy means nothing happens"):
        machine.succeed("echo true > /run/fake-backend/busy")
        machine.succeed(f"htpc-stage --no-activate {nxt}")
        machine.succeed("systemctl start htpc-update.service")

        assert machine.succeed("readlink -f /run/current-system").strip() == base
        machine.fail("test -e /etc/htpc-generation")

        state = json.loads(machine.succeed("cat /var/lib/htpc-update/state.json"))
        assert state["reason"] == "busy", state
        assert state["pending"] == nxt, state
        assert state["reboot_required"] is False, state
        assert state["age_seconds"] >= 0, state

    with subtest("idle means it activates"):
        machine.succeed("echo false > /run/fake-backend/busy")
        machine.succeed("systemctl start htpc-update.service")

        assert machine.succeed("readlink -f /run/current-system").strip() == nxt
        assert machine.succeed("cat /etc/htpc-generation").strip() == "2"
        # Cleared only by a watchdog that saw the generation come up healthy.
        machine.fail("test -e /var/lib/htpc-update/verify-after-reboot")

    with subtest("an unhealthy backend rolls back and marks the revision bad"):
        # --set, not --rollback: --rollback would leave the nxt generation as
        # the profile's immediate predecessor, so the watchdog's own rollback
        # would land back on the revision under test.
        machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {base}")
        machine.succeed(f"{base}/bin/switch-to-configuration switch")
        machine.succeed(": > /var/lib/htpc-update/bad-revisions")
        machine.wait_for_open_port(9600)

        machine.succeed("echo false > /run/fake-backend/healthy")
        machine.succeed(f"htpc-stage --no-activate {nxt}")
        machine.fail("systemctl start htpc-update.service")

        assert machine.succeed("readlink -f /run/current-system").strip() == base
        machine.succeed(f"grep -qxF {nxt} /var/lib/htpc-update/bad-revisions")
        machine.fail("test -L /nix/var/nix/gcroots/htpc-pending")

        state = json.loads(machine.succeed("cat /var/lib/htpc-update/state.json"))
        assert state["reason"] == "rolled-back", state

    with subtest("a known-bad revision is not retried"):
        machine.succeed("echo true > /run/fake-backend/healthy")
        # Refused at the door, so the fifteen-minute timer cannot loop on it.
        machine.fail(f"htpc-stage --no-activate {nxt}")
        machine.succeed("systemctl start htpc-update.service")
        assert machine.succeed("readlink -f /run/current-system").strip() == base
  '';
}
```

- [ ] **Step 3: Register the check**

In `flake.nix`, in the `checks.x86_64-linux` attrset, next to `registry`:

```nix
          staged-updates = import ./nix/tests/staged-updates.nix { inherit pkgs; };
```

- [ ] **Step 4: Run it and watch it pass**

Run: `nix build -L .#checks.x86_64-linux.staged-updates`
Expected: the four subtests print in order and the build succeeds. It takes a few minutes, most of it the unhealthy case waiting out `watchdogSeconds`.

If it fails on `nix-env … --set` with `not a valid store path`, the specialisation symlink was not resolved — check that `readlink -f /run/current-system/specialisation/next` returns a `/nix/store/…` path in the VM.

- [ ] **Step 5: Prove the test can fail**

Temporarily change `requireSignatures = false;` to `true;` in the test node and re-run.

Run: `nix build -L .#checks.x86_64-linux.staged-updates 2>&1 | tail -20`
Expected: the first `htpc-stage` fails with a signature error, so the `busy` subtest fails. Change it back to `false`. A test that cannot fail is not a test.

- [ ] **Step 6: Make CI skip the VM test where there is no KVM**

The runner's job containers run inside an unprivileged LXC, which by default has no `/dev/kvm`, and a `nixosTest` cannot boot a VM without it. Rather than pretend, the job runs the checks it can and says which it skipped.

In `.gitlab-ci.yml`, replace the `flake-check` job's `script`:

```yaml
  script:
    - nix build -L .#checks.x86_64-linux.machine-htpc
    - nix build -L .#checks.x86_64-linux.registry
    # The VM test needs /dev/kvm, which the runner's LXC does not expose
    # today. Skipped loudly rather than silently, and it still gates every
    # local change through `nix flake check`.
    - |
      if [ -e /dev/kvm ]; then
        nix build -L .#checks.x86_64-linux.staged-updates
      else
        echo "no /dev/kvm on this runner; skipping the staged-updates VM test"
      fi
```

If you later pass `/dev/kvm` into the `gitlab-runner` LXC, add `--docker-devices /dev/kvm` to the `Register the Nix runner` task in `ansible/roles/docker/tasks/additional/gitlab-runner.yaml` and the branch above starts taking the first path on its own.

- [ ] **Step 7: Verify the whole check suite locally**

Run: `nix flake check -L`
Expected: no output; `machine-htpc`, `registry` and `staged-updates` all build.

- [ ] **Step 8: Commit**

```bash
git add nix/tests/fake-home-player.py nix/tests/staged-updates.nix flake.nix .gitlab-ci.yml
git commit -m "test(nix): prove the activation policy in a VM

The three things this covers are the ones most likely to ruin an
evening: busy means nothing happens, idle means it activates, and an
unhealthy backend means it rolls back *and* records the revision as bad
so the fifteen-minute timer does not retry the same broken closure
forever.

The second generation is a specialisation of the node's own config. That
is a complete system closure already present in the VM's store, so
nothing has to be built and copied in, and its kernel matches the
parent's -- which is what puts it on the switch path rather than the
reboot one.

The test seeds /nix/var/nix/profiles/system explicitly: a test VM boots
straight from a store path, so without a generation 1 there would be
nothing to roll back to and the test would pass for the wrong reason.

CI skips the VM test where there is no /dev/kvm, loudly rather than
silently -- the runner's LXC does not expose it today.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 16: Close the loop live, and write it down

**Files:**
- Modify: `docs/todo.md`
- Modify: `docs/superpowers/specs/2026-09-06-htpc-nixos-design.md` (status line only)

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Verify a push to home-player reaches the TV, box awake**

Make sure the box is on and the TV is idle (nothing playing). Push a trivial commit to home-player master.

Watch: home-player `check` → terranse pipeline → `deploy-htpc`. Then:

```bash
ssh default-user@htpc.edholm.cc 'sudo journalctl -u htpc-update -n 40 --no-pager'
ssh default-user@htpc.edholm.cc 'readlink -f /run/current-system'
curl -fsS https://nix-cache.edholm.cc/pointers/htpc
```

Expected: the journal shows `activating …` then `is healthy`; the running system equals the published pointer; the kiosk is still on screen. Confirm the TV did not blank for more than the moment `home-player-shell` restarts.

- [ ] **Step 2: Verify busy defers the update**

```bash
# Start something playing on the TV, then:
ssh default-user@htpc.edholm.cc 'curl -fsS http://127.0.0.1:9600/system/activity || echo "endpoint absent"'
```

If the endpoint is absent (it is home-player's phase-5 work), simulate the decision instead and record that this is a simulation, not the real signal:

```bash
ssh default-user@htpc.edholm.cc 'sudo systemctl start htpc-update.service; sudo cat /var/lib/htpc-update/state.json'
```

Expected with the endpoint present and playback running: `"reason": "busy"` and the running system unchanged. Expected with it absent: `"reason": "none"` — and note in `docs/todo.md` that the busy path is proved only by the `nixosTest` until home-player ships `/system/activity`.

- [ ] **Step 3: Verify the sleeping-box path**

```bash
ssh default-user@htpc.edholm.cc sudo poweroff
# push a trivial commit to home-player master, watch the pipeline go GREEN
```

Expected: `deploy-htpc` is green and its log ends with `did not answer; it will pull from the cache on next boot`. A sleeping television must never turn a pipeline red.

Then power the box on (or let CI's next `wakeonlan` do it) and:

```bash
ssh default-user@htpc.edholm.cc 'sudo journalctl -u htpc-update-fetch -n 30 --no-pager'
ssh default-user@htpc.edholm.cc 'readlink -f /run/current-system'
curl -fsS https://nix-cache.edholm.cc/pointers/htpc
```

Expected: the fetch unit logs `fetching /nix/store/…` and the running system now equals the pointer. This is the path that catches every push where WoL did not land.

- [ ] **Step 4: Verify wake-on-LAN actually wakes it**

```bash
ssh default-user@htpc.edholm.cc sudo systemctl suspend
sleep 20
wakeonlan -i 192.168.1.255 <the MAC from Task 3 Step 5>
sleep 30
ssh default-user@htpc.edholm.cc hostname
```

Expected: `htpc`. If the box does not wake, the failure is one of three: BIOS WoL off (Task 3 Step 4), `ethtool` reporting `Wake-on: d` (check `home-player-wol.service`), or the magic packet not crossing from the runner's docker network. Test the last one from the runner itself:

```bash
ssh default-user@gitlab-runner.edholm.cc \
  'docker run --rm --network host nixos/nix:latest \
     nix --extra-experimental-features "nix-command flakes" \
     run nixpkgs#wakeonlan -- -i 192.168.1.255 <MAC>'
```

If that wakes the box but the CI job does not, add `--docker-network-mode host` to the Nix runner's registration in `ansible/roles/docker/tasks/additional/gitlab-runner.yaml` and re-converge.

- [ ] **Step 5: Verify a bad revision rolls back on real hardware**

Deliberately break the box, once, on purpose. In `nix/machines.nix` temporarily set the backend's URL to something unreachable so `/health` never answers:

```nix
        settings = {
          web.enable = true;
          jellyfinUrl = "https://jellyfin.edholm.cc";
          sonarrUrl = "https://sonarr.edholm.cc";
          radarrUrl = "https://radarr.edholm.cc";
          secretsFile = "/var/lib/home-player-secrets/does-not-exist";
        };
```

`environmentFile` has no `-` prefix, so the backend unit fails to start and `/health` never answers — exactly the shape of a bad revision.

```bash
NIX_CACHE_DIR=$(mktemp -d) SSH_WAIT_SECONDS=30 ./scripts/ship.sh htpc
ssh default-user@htpc.edholm.cc 'sudo journalctl -u htpc-update -u htpc-update-watchdog -n 60 --no-pager'
ssh default-user@htpc.edholm.cc 'readlink -f /run/current-system; sudo cat /var/lib/htpc-update/bad-revisions'
```

Expected: the watchdog logs `never became healthy; rolling back`, the running system is the previous one, the bad path is listed, and the TV is showing the home screen again. Revert `nix/machines.nix`, re-deploy, and confirm the *new* (different) revision activates normally — the bar is per-path, not permanent.

- [ ] **Step 6: Record what actually happened**

Append to `docs/todo.md`, under a new `### HTPC` heading in the `## Services` section:

```markdown
### HTPC (NixOS)

- [x] NixOS on the box, declared in `nix/machines.nix`, reachable at
      `htpc.edholm.cc` (reserved `192.168.1.51`)
- [x] ZFS root (`rpool`) declared with disko, so the machine and its installer
      ISO both build from the flake before the hardware is touched.
      Re-installing is `just iso` + one `nixos-anywhere` command.
- [x] home-player backend + kiosk shell autostarting on cold boot
- [x] Signed closures published to `https://nix-cache.edholm.cc` by CI on
      `gitlab.com/yarcod/{terranse,home-player}`
- [x] Staged updates: idle-gated activation, watchdog rollback, boot-time
      pull when wake-on-LAN did not land
- [ ] `/system/activity` and the update popup — home-player's side. Until it
      ships, the busy path is proved only by the `staged-updates` nixosTest;
      a failed request reads as idle, so the box updates whenever it is up.
- [ ] Escalation for a box that is never idle: a pending kernel update could
      sit indefinitely. `state.json` carries its age so it is at least
      visible; deliberately not guessed at now.
- [ ] The watchdog is only as good as the health signal. `/health` returning
      200 while the UI renders blank would not trigger a rollback; requiring
      the kiosk user unit narrows this but does not close it.
- [ ] The watchdog runs inside `htpc-update.service` and its rollback calls
      `switch-to-configuration switch`, which may restart the very unit it is
      running from. Not observed in the `nixosTest` (both generations differ
      by one file in /etc), and not observed live in Task 16 Step 5 — but if a
      rollback ever ends with the journal cut off mid-sentence, move the
      watchdog into its own transient unit with `systemd-run`.
```

- [ ] **Step 7: Mark the spec implemented**

In `docs/superpowers/specs/2026-09-06-htpc-nixos-design.md`, change line 4 from
`Status: approved, not yet implemented` to
`Status: implemented (phases 1-4, 2026-09-06); phase 5 (the popup) is home-player's`.

- [ ] **Step 8: Commit**

```bash
git add docs/todo.md docs/superpowers/specs/2026-09-06-htpc-nixos-design.md
git commit -m "docs: record the HTPC as live, and what is still open

Phases 1-4 are done and verified on the box: a push to home-player
master builds, signs, publishes and activates, rolling back a revision
that does not come up healthy and pulling from the cache on the next
boot when wake-on-LAN did not land.

Three things are recorded rather than hidden. The busy path is only
proved by the nixosTest until home-player ships /system/activity, since
a failed request reads as idle by design. A box that is never idle never
reboots, so a pending kernel update could sit indefinitely -- state.json
carries its age so it is visible, and an escalation policy is deferred
rather than guessed at. And the watchdog is only as good as the health
signal.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Verification

End-to-end, after all sixteen tasks:

```bash
# 1. Everything the flake claims, built from scratch
cd /home/daniele/Repos/terranse
nix flake check -L

# 2. The declared machine matches what is running
ssh default-user@htpc.edholm.cc 'readlink -f /run/current-system'
nix build --no-link --print-out-paths \
  .#nixosConfigurations.htpc.config.system.build.toplevel
#    -> the two paths must be identical

# 3. The published pointer matches too
curl -fsS https://nix-cache.edholm.cc/pointers/htpc

# 4. The closure is signed by the builder key the box trusts
STORE_PATH=$(curl -fsS https://nix-cache.edholm.cc/pointers/htpc)
curl -fsS "https://nix-cache.edholm.cc/$(basename "$STORE_PATH" | cut -d- -f1).narinfo" | grep '^Sig:'
ssh default-user@htpc.edholm.cc 'grep trusted-public-keys /etc/nix/nix.conf'

# 5. The box does its job
ssh default-user@htpc.edholm.cc 'systemctl is-active home-player-backend.service'
ssh default-user@htpc.edholm.cc 'systemctl --user --machine=tv@.host is-active home-player-shell.service'
ssh default-user@htpc.edholm.cc 'curl -fsS http://127.0.0.1:9600/health'

# 6. The update machinery is armed
ssh default-user@htpc.edholm.cc 'systemctl is-active htpc-update.timer'
ssh default-user@htpc.edholm.cc 'sudo cat /var/lib/htpc-update/state.json | jq .'

# 7. CI has exactly one privilege on the box, and it is not root
ssh default-user@htpc.edholm.cc 'sudo -l -U deploy'
#    -> only /run/current-system/sw/bin/htpc-stage, NOPASSWD

# 8. Tofu is clean
just validate-tofu
cd tofu/deployments/edholm && tofu plan -var-file=configurations.tfvars
#    -> "No changes."
```

Then the real test: push a one-line change to home-player master, and watch it appear on the television without touching anything.

## What this plan deliberately does not build

- **`/system/activity` and the update popup UI.** home-player's repo, phase 5 of the spec. This plan fixes the contract (`state.json`'s shape, `htpc-update-apply.service`, the polkit rule scoped to that single unit) and works correctly with the endpoint absent.
- **TV power control.** The box has no CEC and `withCec` does not build in a pure Nix sandbox. Home Assistant already has an entry for the TV and is the intended route.
- **RF/BT remote pairing and wake-from-remote.**
- **`ipid`-based access and trust.** Deliberately not pre-built. LAN DNS plus SSH is enough until it lands, and nothing here has to be unpicked to adopt it.
- **Netbird enrolment.**
- **A second NixOS machine.** The registry, the per-host secrets template and `ship.sh` are all shaped so adding one is mechanical, but none of it is generalised speculatively.
