# `herdr` — a NixOS LXC build-and-agent box on `workstation`

## Context

You want an always-on machine that builds your projects (mostly Rust) and runs
AI coding agents, fronted by **herdr** — a Rust agent multiplexer (tmux for
coding agents; client/server, so panes survive detach, and `herdr --remote
<host>` streams the remote UI back over stock SSH). It should be an LXC on
`workstation` with 12 cores and 32 GB, and it should be declared in Nix the way
the approved-but-unbuilt HTPC design declares the TV box.

Two things make this more than "add a tfvars block":

1. **terranse has no `flake.nix` yet.** The HTPC plan
   (`docs/superpowers/plans/2026-09-06-htpc-nixos.md`, Task 2) is what was
   going to create it. You asked this work to bootstrap it instead — either
   honouring that layout or improving on it with justification. It needs one
   real improvement (below), so the HTPC plan gets amended.
2. **Nothing in the repo can make a NixOS container.**
   `tofu/modules/proxmox-container` resolves *one* Debian template per Proxmox
   node off `download.proxmox.com`, and every container it creates is
   unconditionally handed an apt-based `proxmox/lxc` Ansible play plus an SSH
   hardening play that edits `/etc/ssh/sshd_config` — both fatal on NixOS.

**Outcome:** `herdr.edholm.cc`, a NixOS 12c/32 GB/200 GB unprivileged CT on
`workstation`, built from `nixosConfigurations.herdr` in terranse's own flake,
updated with `nixos-rebuild switch --target-host`, never touched by Ansible,
running `pkgs.herdr` + `pkgs.claude-code` + a rustup-based Rust toolchain. Plus
`herdr` added to `computer-configs` so the laptop can drive it remotely.

**Naming note:** the machine and the tool share the name (your call). Read
`herdr` as the host wherever it appears in a path or a hostname, and as the
binary wherever it appears in `environment.systemPackages` or a command line.

---

## The flake layout, and how it differs from the HTPC plan

The HTPC plan's Task 2 skeleton is kept almost intact — `flake.nix` at the
repo root, `nix/lib/registry.nix`, `nix/roles/{default,base}.nix`,
`nix/machines.nix`, `nix/hosts/<name>/`, `nix/tests/registry.nix`, the
`roles.<name>.enable` convention, `nix flake check` building every machine's
toplevel. Three deliberate changes, all forced by the container:

### 1. A `kind` on each machine, and `nix/profiles/{metal,lxc}.nix` — **required**

The plan's `base.nix` sets `boot.loader.systemd-boot.enable = true`. nixpkgs'
`virtualisation/proxmox-lxc.nix` sets `boot.loader.initScript.enable = true`.
Both define `system.build.installBootLoader`, which is a plain option with no
merge function — so a container that imports the plan's `base.nix` **fails to
evaluate**, with a definition conflict. This is not a warning to suppress.

So the firmware-and-disk assumptions leave `base.nix` for a profile selected by
`kind`:

- `nix/profiles/metal.nix` — imports `inputs.disko.nixosModules.disko`, sets
  `boot.loader.systemd-boot.enable`, `boot.loader.efi.canTouchEfiVariables`.
- `nix/profiles/lxc.nix` — imports `(modulesPath +
  "/virtualisation/proxmox-lxc.nix")`, which sets `boot.isContainer = true`.
  That one flag turns off the kernel, the initrd, grub, udev and — via
  `nixos/modules/system/boot/stage-1.nix` — the *"does not specify your root
  file system"* assertion. **This is why an LXC machine needs no `disko.nix`
  and no `hardware.nix` at all.**

`nix/profiles/default.nix` is a `name -> path` attrset mirroring
`nix/roles/default.nix`; an unknown `kind` throws a message naming the machine
and listing the valid kinds, same idiom as the role registry.

### 2. `system.stateVersion` moves from `base.nix` to `nix/hosts/<name>/default.nix`

The plan hardcodes `"26.05"` fleet-wide. `stateVersion` is a statement about
which release a *particular* machine's state was created under; `herdr` is
created against current unstable and must say so. A shared value silently
becomes wrong for machine #2.

### 3. `disko` moves out of `mkMachine`'s unconditional module list

Into `metal.nix`. Otherwise every container drags the disko module in for
nothing.

### `mkMachine` after the change

```nix
mkMachine = hostname: { system, roles ? [ ], kind ? "metal" }:
  lib.nixosSystem {
    inherit system;
    specialArgs = { inherit inputs hostname; };
    modules = [
      (profiles.${kind} or (throw "nix/machines.nix: machine '${hostname}' has unknown kind '${kind}'. Valid kinds are: ${lib.concatStringsSep ", " (builtins.attrNames profiles)}."))
      ./nix/hosts/${hostname}
      roleModules.base
      { networking.hostName = hostname; }
    ]
    ++ registry.modulesFor roleModules hostname roles
    ++ map (r: { roles.${r.name} = { enable = true; } // (r.settings or { }); }) roles;
  };
```

### How the HTPC plan must be adjusted

`docs/superpowers/plans/2026-09-06-htpc-nixos.md` — Task 2 shrinks to "add the
htpc host". Specifically:

| HTPC plan step | Change |
|---|---|
| Task 2 Steps 1–3 (registry + `nix/roles/default.nix` + registry test) | **Already done** by Task 1 below. Skip. |
| Task 2 Step 4 (`nix/machines.nix`) | Add `htpc = { system = "x86_64-linux"; kind = "metal"; roles = [ ]; };` to the existing file rather than creating it. |
| Task 2 Step 5 (`nix/roles/base.nix`) | **Already exists.** Only edit needed: paste the Task 1 public keys into `users.users.deploy.openssh.authorizedKeys.keys` and `nix.settings.trusted-public-keys`. Do **not** re-add `boot.loader.*` or `system.stateVersion` — they live in `nix/profiles/metal.nix` and `nix/hosts/htpc/default.nix` now. |
| Task 2 Steps 6–7 (`disko.nix`, `hardware.nix`, `hosts/htpc/default.nix`) | Unchanged, except `hosts/htpc/default.nix` also carries `system.stateVersion = "26.05";`. |
| Task 2 Step 8 (`flake.nix`) | **Already exists.** No change. |
| Task 2 Step 9 (`.gitignore`) | Already done. |
| Tasks 3, 4, 7, 9, 10–16 | Unchanged. |

Add one line to the HTPC plan's Global Constraints: *"`nix/profiles/` and the
`kind` attribute already exist — see the herdr plan. `base.nix` is shared and
must stay free of bootloader and disk assumptions."*

---

## Task 1 — Bootstrap the flake

**Create:** `flake.nix`, `nix/lib/registry.nix`, `nix/roles/default.nix`,
`nix/roles/base.nix`, `nix/profiles/{default,metal,lxc}.nix`,
`nix/machines.nix`, `nix/tests/registry.nix`. **Modify:** `.gitignore`.

Take `nix/lib/registry.nix`, `nix/tests/registry.nix` and `nix/roles/base.nix`
verbatim from HTPC plan Task 2 Steps 1–3 and 5, with these edits to `base.nix`:

- drop `boot.loader.systemd-boot.enable` and `boot.loader.efi.canTouchEfiVariables`
- drop `system.stateVersion`
- leave the `deploy` user's key and the extra `trusted-public-keys` entry as
  `REPLACE-…` placeholders (HTPC Task 1 generates them; nothing here needs
  them, and `nix flake check` does not care what a public key string contains)
- keep `nix.optimise.automatic = true` — `container-config.nix` forces it off
  inside a container anyway, so it costs nothing and stays right for metal

`nix/profiles/lxc.nix`:

```nix
# An unprivileged Proxmox CT. proxmox-lxc.nix sets boot.isContainer, which
# turns off the kernel, the initrd, grub and udev -- and with them the
# "fileSystems does not specify your root file system" assertion. That is why
# an LXC machine needs neither disko.nix nor hardware.nix.
{ modulesPath, ... }:
{
  imports = [ (modulesPath + "/virtualisation/proxmox-lxc.nix") ];

  proxmoxLXC = {
    privileged = false;    # adds the ping capability wrapper, drops the debugfs mount
    manageNetwork = false; # Proxmox writes /etc/systemd/network/eth0.network from
                           # net0, so tofu stays the single source of truth for the
                           # MAC and the addressing.
    manageHostName = true; # WITHOUT this the module does `networking.hostName =
                           # mkForce ""`, silently discarding mkMachine's hostname.
  };

  # proxmox-lxc.nix suppresses /sys/kernel/debug; these three it does not, and
  # none of them can succeed in an unprivileged CT.
  systemd.suppressedSystemUnits = [
    "dev-mqueue.mount"
    "sys-kernel-debug.mount"
    "sys-fs-fuse-connections.mount"
  ];

  # networkd hands the DHCP nameservers to resolved. Without it the boot-time
  # `resolvconf -u` has no subscriber and /etc/resolv.conf can come up empty.
  services.resolved.enable = true;
}
```

`nix/machines.nix` starts with `herdr` only; `htpc` arrives with the HTPC plan.

`flake.nix` as in HTPC Task 2 Step 8, plus:
- `let profiles = import ./nix/profiles;`
- the `mkMachine` shown above
- `packages.x86_64-linux.herdr-lxc-template =
  self.nixosConfigurations.herdr.config.system.build.tarball;`

**Verify:** `nix flake check` passes (it builds `herdr`'s toplevel and runs the
registry test). `nix eval .#nixosConfigurations.herdr.config.system.build.installBootLoader`
resolves without a conflict.

**Commit:** `feat(nix): bootstrap the fleet flake and its role registry`

---

## Task 2 — The `dev` role

**Create:** `nix/roles/dev.nix`. **Modify:** `nix/roles/default.nix` (one line:
`dev = ./dev.nix;`).

`options.roles.dev` = `{ enable, user ? "default-user", workspace ? "/srv/work" }`.

Key decisions, with reasons:

- **rustup, not fenix/rust-overlay.** This box builds *your repos*, and
  `ipid/rust-toolchain.toml` pins `nightly-2026-06-15` with specific components
  and targets. Only rustup reads `rust-toolchain.toml` automatically; the flake
  overlays would need a `flake.nix` in every repo an agent might clone, and
  would pin the toolchain in terranse rather than in the repo that owns it.
  The usual "rustup's binaries want `/lib64/ld-linux`" objection does not
  apply — `pkgs.rustup` carries a patch that patchelfs every toolchain it
  downloads. It also matches `computer-configs/home/packages.nix:76-82`, so
  laptop and box behave identically.
- **`programs.nix-ld.enable = true`.** Non-negotiable on an agent box: agents
  run `npm -g`, `uv tool install`, and download prebuilt language servers,
  none of which are patchelfed.
- **`nix.settings.trusted-users = [ "root" "default-user" ]`.** Needed for
  `nixos-rebuild --target-host default-user@…` to receive a closure. It grants
  nothing you don't already have — `base.nix` gives `default-user` passwordless
  wheel sudo.
- **`nix.settings.max-jobs = 6; cores = 2;`** — 12 cores, but rustc
  parallelises internally; this keeps the box responsive while agents work.
- Do **not** set `auto-allocate-uids`: it allocates UIDs outside an unprivileged
  CT's 65536-entry idmap and builds die with `cannot kill processes for uid
  '872415232'`.

Packages: `rustup`, `stdenv.cc`, `gnumake`, `pkg-config`, `mold`, `sccache`,
`openssl.dev`, `zlib`, `cargo-nextest`, `cargo-edit`, `cargo-watch`, `herdr`,
`claude-code`, `nodejs_22`, `uv`, `git`, `git-lfs`, `direnv`, `nix-direnv`,
`ripgrep`, `fd`, `jq`, `just`, `tmux`, `helix`.

`claude-code` is unfree — use `nixpkgs.config.allowUnfreePredicate` naming it
explicitly, not blanket `allowUnfree`, so an accidental unfree dependency
elsewhere still fails loudly.

Environment: `RUSTUP_HOME`, `CARGO_HOME`, `CARGO_TARGET_DIR`, `SCCACHE_DIR`
(40 G) all under `cfg.workspace`, created by `systemd.tmpfiles.rules` owned by
`cfg.user`. Keep the workspace off `$HOME` so it can become its own dataset or
a host bind-mount later without moving anything.

**One caveat to write into the file:** do *not* set `RUSTFLAGS` globally for
mold. Cargo does not merge `RUSTFLAGS` with a repo's `[build] rustflags`, it
replaces it — and `ipid`'s eBPF crate uses `build-std` via its own
`.cargo/config.toml`. Put mold in `$CARGO_HOME/config.toml` under
`[target.x86_64-unknown-linux-gnu] linker`/`rustflags` instead, or leave linker
choice to the repos.

**Verify:** `nix build .#nixosConfigurations.herdr.config.system.build.toplevel`.

**Commit:** `feat(nix): add the dev role -- Rust toolchain and coding agents`

---

## Task 3 — The `herdr` host and its template

**Create:** `nix/hosts/herdr/default.nix` — the only file this host needs.

```nix
{
  # Stable filename. The default is
  # nixos-image-<system.nixos.label>-x86_64-linux.tar.xz, whose label carries
  # the nixpkgs revision -- so the name would change on every flake update and
  # tofu's `ostemplate` string would have to chase it.
  image.baseName = "nixos-lxc-herdr";

  # Per-host, not fleet-wide: this machine's state was created under this
  # release. Confirm against `nixos-version` on first boot.
  system.stateVersion = "26.11";
}
```

`nix/machines.nix`:

```nix
{
  herdr = {
    system = "x86_64-linux";
    kind   = "lxc";
    roles  = [ { name = "dev"; } ];
  };
}
```

**Create:** `scripts/push-lxc-template.sh` — build the tarball and scp it to the
node's `vztmpl` directory. `/var/lib/vz/template/cache` *is* the `vztmpl`
directory of the `local` dir-storage, and `pveam` is only a downloader, so a
file dropped there is a first-class template with no registration step.

```bash
nix build .#herdr-lxc-template
scp -O result/tarball/nixos-lxc-herdr.tar.xz \
    root@192.168.1.200:/var/lib/vz/template/cache/nixos-lxc-herdr.tar.xz
ssh root@192.168.1.200 'pveam list local | grep nixos-lxc-herdr'
```

Add a `just` recipe wrapping it.

**Commit:** `feat(nix): declare the herdr container and its LXC template`

---

## Task 4 — Teach tofu about foreign templates and unmanaged containers

Three optional attributes, one `coalesce`, one `if`. Nothing else moves.

**`tofu/modules/proxmox-container/variables.tf`** — inside the `configuration`
object type:

```hcl
    # Full Proxmox volume id of a template built elsewhere -- e.g. a NixOS
    # rootfs tarball from `nix build .#<name>-lxc-template`, scp'd into
    # /var/lib/vz/template/cache. When set, the module-level Debian template
    # resolution does not apply to this container.
    ostemplate = optional(string)

    # pct ostype. "nixos" makes PVE write /etc/systemd/network/eth0.network and
    # /etc/resolv.conf but skip the hostname and init rewrites that would fight
    # a NixOS activation. Leave unset for Debian.
    ostype = optional(string)

    # "ansible" (default) emits the proxmox/lxc play. "none" emits no play at
    # all, for machines whose configuration is owned by the flake. The
    # inventory entry, the deterministic MAC and the DHCP reservation are
    # unaffected.
    provision = optional(string, "ansible")
```

**`tofu/modules/proxmox-container/main.tf:71`** — two lines inside
`resource "proxmox_lxc" "lxcs"`:

```hcl
  ostemplate = coalesce(each.value.ostemplate, "local:vztmpl/${local.image_name}")
  ostype     = each.value.ostype
```

`ostype` is Optional+Computed in the telmate provider, so `null` sends nothing
and produces no perpetual diff. `ostemplate` is already inside
`lifecycle { ignore_changes = [...] }`, so re-uploading a same-named tarball
never triggers a replace — correct, since updates go through `nixos-rebuild`.

**`tofu/modules/proxmox-container/outputs.tf`** — one clause on `ansible_plays`:

```hcl
    if host_config.provision != "none"
```

This does **two** jobs. It drops the apt-based `proxmox/lxc` play, and —
because `tofu/modules/ansible-wiring/main.tf:21` builds `all_container_hosts`
by joining `play.hosts` — it also drops `herdr` from the *"Harden SSH — disable
root login on all containers"* play appended at
`ansible-wiring/main.tf:39-58`. That play does `lineinfile` on
`/etc/ssh/sshd_config` (a read-only store symlink on NixOS) and restarts a
service named `ssh` (which does not exist on NixOS); without this clause it
would fail on every run. `inventory.tf` is a separate `for_each` and is
untouched, so `herdr.edholm.cc` stays in the inventory under the `workstation`
group with no plays attached — exactly the arrangement HTPC Task 5 Step 10
verifies for a NixOS machine.

**`tofu/deployments/edholm/configurations.tfvars`** — under `workstation.lxcs`
(`var.hosts` is typed `any`, so no other type change is needed):

```hcl
      # NixOS, built from nixosConfigurations.herdr in this repo's flake.
      # tfvars declares identity and shape; nix/machines.nix declares what it
      # runs. provision = "none" is what keeps Ansible off it.
      herdr = {
        memory     = 32768
        cores      = 12
        disk_size  = "200G"
        ostemplate = "local:vztmpl/nixos-lxc-herdr.tar.xz"
        ostype     = "nixos"
        provision  = "none"
        roles      = []
      }
```

**`tofu/deployments/edholm/defaults.tf`** — `lxc_reserved_ips` gains
`herdr = "192.168.1.52"` (`.51` is claimed by the HTPC plan).

Everything else is free: `local.mac_addresses` keys off
`keys(var.configuration)`, so `herdr` gets `BC:24:11:<sha256("herdr")[0:6]>`,
its `mac_collision_guard`, its `lxc_name_uniqueness_guard` entry, and its
dnsmasq reservation with no further work. `features { nesting = true }` is
already hardcoded, which is the one feature the Nix build sandbox needs.
`keyctl` is deliberately **not** wanted here: with it off, `keyctl()` returns
ENOSYS and systemd-networkd is happy; with it on, networkd can see EPERM and
abort.

**Verify:** `just validate-tofu`, then `cd tofu/deployments/edholm && tofu plan
-var-file=configurations.tfvars` — expect exactly one `proxmox_lxc` to add, one
`opnsense_dnsmasq_host.reservation["herdr"]`, the two guards updating, and
**no** changes to any existing container.

**Commit:** `feat(tofu): allow a container to bring its own template and skip ansible`

---

## Task 5 — Build, create, and first boot

1. `just push-lxc-template herdr` (Task 3).
2. `just apply-tofu edholm`.
3. **If `pct start` refuses** with a message about the configured ostype
   differing from the auto-detected type, fall back: set `ostype = "unmanaged"`
   in tfvars and flip `nix/profiles/lxc.nix` to `manageNetwork = true` with an
   explicit `systemd.network.networks."10-eth0"` doing DHCPv4 on `eth0`. That
   version depends on nothing PVE writes into the rootfs. (See Risks.)
4. `ssh default-user@herdr.edholm.cc` — the fleet key from `base.nix` is already
   in the image, so there is no bootstrap phase and no `just setup`.
5. **Prove the Nix sandbox works before trusting the box.** `base.nix` leaves
   `sandbox = true`, and NixOS sets `sandbox-fallback = false`, so a sandbox
   that cannot be built is a hard failure rather than a silent degradation:

   ```bash
   nix config show | grep -E '^(sandbox|sandbox-fallback) '
   nix build --no-link --rebuild nixpkgs#hello
   ```

   If it fails with `mounting /proc: Operation not permitted`, the ladder is:
   confirm `nesting=1` on the CT → `lxc.apparmor.profile: unconfined` in
   `/etc/pve/lxc/<vmid>.conf` → `nix.settings.sandbox = "relaxed"` → make it a
   VM. Only the last is clean; do not reach for `relaxed` first, because it
   would hide a real misconfiguration and make this box's builds differ from
   CI's.
6. Confirm lxcfs is masking correctly: `nproc` → 12, `free -g` → 32.

**Steady-state updates**, from the laptop — the box compiles for itself:

```bash
nixos-rebuild switch --flake .#herdr \
  --target-host default-user@herdr.edholm.cc \
  --build-host  default-user@herdr.edholm.cc \
  --elevate=sudo
```

`root@` will not work (`base.nix` sets `PermitRootLogin = "no"`).
`--elevate=sudo` is the current spelling of `--use-remote-sudo`. Add a
`just deploy-nixos <machine>` recipe. `nixos-rebuild boot` also works and is
cheap here — `boot.kernel.enable = false` means generations carry no kernel —
staging for the next `pct reboot`.

The template only needs rebuilding if you destroy and recreate the container.
Because `ostemplate` is under `ignore_changes`, a stale template on the host is
invisible to tofu: if you ever `tofu taint` `herdr`, re-push the template first.

---

## Task 6 — Claude Code authentication (both paths)

The browser problem is solved and documented: **the OAuth flow has an official
copy-paste code fallback for exactly this case.** Per
[Troubleshoot install](https://code.claude.com/docs/en/troubleshoot-install#oauth-login-fails-in-wsl2-ssh-or-containers)
— *"This happens when the browser can't reach Claude Code's local callback
server, which is common in WSL2, SSH sessions, and containers"* — you press `c`
to copy the URL, sign in on the laptop's browser, and paste the code back into
the SSH session. `claude auth login` is the variant that reads the pasted code
from stdin if the TUI misbehaves. **Do not build anything around SSH
port-forwarding the callback**: the port is undocumented and has changed
between versions.

Both paths, as you asked:

**Interactive (normal use).** Document it in the runbook; nothing to build.
Credentials land in `~/.claude/.credentials.json` on the box and persist.
Caveat worth writing down: `/login` credentials expire, and Claude Code warns
`Your login expires in 3 days`. A long-running agent session that outlives the
credential stops making progress until you sign in again.

**Long-lived token (unattended).** Run `claude setup-token` **on the laptop**
(it needs a browser, and does not save the token anywhere), store it in
1Password, and deliver it to the box as `CLAUDE_CODE_OAUTH_TOKEN` using the
HTPC plan's Task 8 machinery — `nix/hosts/herdr/secrets.env.tpl` holding only
`op://` references, rendered on the laptop with `op inject` and piped over SSH
by `just secrets herdr`. Re-running it is the whole rotation procedure; the
token lasts a year. Have `roles.dev` read it via
`systemd`/`environment.etc` from the rendered file rather than
`environment.variables`, so no secret enters the store.

Two behaviours to record in the runbook because they bite silently:
- A stray `ANTHROPIC_API_KEY` in the box's environment **outranks** both
  `CLAUDE_CODE_OAUTH_TOKEN` and `/login`. Don't set one.
- The long-lived token can only make model requests — no Remote Control
  sessions, no claude.ai connectors. That is why the interactive path stays the
  normal one.

Set `DISABLE_AUTOUPDATER=1` so the vendored auto-updater does not fight the
declarative `pkgs.claude-code` install.

**Commit:** `feat(nix): deliver the claude oauth token from 1password`

---

## Task 7 — `herdr` on the laptop

**Modify:** `computer-configs/home/packages.nix` — add `herdr` next to the
existing `claude-code-nix` and `crush` entries, with a comment saying it is the
client half for `herdr --remote herdr.edholm.cc`. `pkgs.herdr` is in nixpkgs
(verified: 0.8.0 in your current pin, 0.8.2 on unstable), so no flake input is
needed. There is no home-manager module for it yet
([nix-community/home-manager#9566](https://github.com/nix-community/home-manager/issues/9566)).

Apply with `just apply` in `computer-configs`.

Two things to check when you first run `herdr --remote`: it manages its own SSH
control socket and, by default, writes `~/.ssh/config` entries (set
`[remote].manage_ssh_config = false` if you'd rather it didn't) — and your fish
config auto-starts Zellij on every non-nested interactive shell
(`home/terminal.nix:134-145`), which is worth knowing if remote panes behave
oddly.

**Commit (in computer-configs):** `feat(packages): add herdr`

---

## Task 8 — Write it down

**Modify:** `docs/superpowers/plans/2026-09-06-htpc-nixos.md` with the Task 2
amendments from the table above, plus the new Global Constraint.
**Create:** `docs/superpowers/plans/2026-09-07-herdr-nixos-lxc.md` — this plan.
**Modify:** `README.md` with a short "NixOS machines" section: `nix/` layout,
`kind`, `just push-lxc-template`, `just deploy-nixos`.

---

## Verification

```bash
# 1. Everything the flake claims, from scratch
nix flake check

# 2. The declared machine matches what is running
nix build --no-link --print-out-paths .#nixosConfigurations.herdr.config.system.build.toplevel
ssh default-user@herdr.edholm.cc readlink /run/current-system
#    -> identical paths

# 3. Ansible never touches it
cd ansible && ansible-inventory -i inventory/edholm.yaml --host herdr.edholm.cc
grep -c 'herdr' playbooks/edholm.yaml    # -> 0

# 4. Shape and address
ssh default-user@herdr.edholm.cc 'nproc; free -g; ip -4 addr show scope global | grep inet'
#    -> 12, ~32, 192.168.1.52
ssh -p 2223 root@opnsense.edholm.cc 'grep -r herdr /usr/local/etc/dnsmasq.conf.d/'

# 5. It can actually build (the whole point)
ssh default-user@herdr.edholm.cc 'nix build --no-link --rebuild nixpkgs#hello'
ssh default-user@herdr.edholm.cc 'cd /srv/work && git clone <a rust repo> r && cd r && cargo nextest run'

# 6. The agents are there and authenticated
ssh default-user@herdr.edholm.cc 'herdr --version; claude --version; claude auth status'

# 7. Redeploy end to end
nixos-rebuild switch --flake .#herdr --target-host default-user@herdr.edholm.cc \
  --build-host default-user@herdr.edholm.cc --elevate=sudo

# 8. Tofu is clean
just validate-tofu && cd tofu/deployments/edholm && tofu plan -var-file=configurations.tfvars
#    -> "No changes."
```

---

## Risks, ordered by how likely they are to bite

1. **The Nix build sandbox in an unprivileged CT.** Every source agrees that
   `nesting=1` (which the module already sets) is what makes it work, and the
   mechanism is sound — `nix-daemon` runs as container root and so holds
   `CAP_SYS_ADMIN` *within* the container's user namespace. But it is not
   verified on your PVE 9 host. Task 5 Step 5 is the go/no-go, and the fallback
   ladder is written there. This risk does not exist in a VM.
2. **`ostype = "nixos"`.** `PVE::LXC::Setup::NixOS.pm` is a real upstream
   plugin whose hostname/init hooks are deliberate no-ops, and `nixos` is in
   `pct`'s `--ostype` enum. What is unconfirmed is that PVE's auto-detection
   classifies a NixOS rootfs as `nixos` — and `pct` documents that start fails
   if the configured type differs from the detected one. Task 5 Step 3 is the
   fallback, and it is arguably the safer default anyway.
3. **Memory headroom on `workstation`.** `gitlab-runner` 32 G + `vagrant-runner`
   16 G + `herdr` 32 G + the `gaming` VM's 32 G. LXC memory is a cgroup *cap*,
   not a reservation, so the containers coexist fine — but the VM's 32 G is
   real. Check `free -g` on `192.168.1.200` before applying. (My read-only SSH
   attempt during planning timed out, so this is genuinely unchecked.)
4. **No `/dev/kvm`.** This box cannot run `nixosTest`, Vagrant, or load an eBPF
   program — only build one. HTPC plan Task 15 adds a `nixosTest` to the flake's
   checks, so `nix flake check` in full stays a laptop/CI job.
   `ansible/roles/proxmox/lxc/tasks/devices/add-kvm-device.yaml` shows you have
   passed `/dev/kvm` into an LXC before if this ever matters.
5. **200 GB is a guess.** You didn't specify a disk. `pct resize` grows it
   online, so starting smaller is cheap to undo — but check `NVMePool` free
   space first.
6. **Two deploy paths for one fleet.** disko + nixos-anywhere for metal, tarball
   + `pct create` for containers. Accepted deliberately: on a node already
   reserving 32 G for the gaming VM, an LXC's elastic memory and shared ZFS ARC
   are worth more to a compile box than the `/dev/kvm` it gives up.
