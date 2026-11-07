# HTPC: headless install, encrypted disk, Plasma, nightly updates

Date: 2026-11-05
Status: draft, awaiting approval
Changes: [2026-09-06-htpc-nixos-design.md](2026-09-06-htpc-nixos-design.md).
Anything not mentioned here still stands, including its activation policy and
its 1Password secrets model.

## Why

A new HP mini PC is going behind the TV to run Home Player. The owner wants to
install it without a screen, then never open a terminal or desktop to keep it
current. The first idea was Kubuntu with an autoinstall file. Two findings
changed that:

- The Kubuntu 26.10 ISO uses Calamares, with no Subiquity or Curtin in it, so
  it cannot read an autoinstall file.
- Nix would manage the box anyway, and terranse already declares an `htpc`
  NixOS machine with a disk layout and tested staged updates.

The owner has accepted NixOS on that basis.

## The machine

Read from the box on 2026-11-05, from a RAM-only boot:

| Part | Value |
|---|---|
| Model | HP EliteDesk 800 G5 Desktop Mini, BIOS R21 02.21.01 |
| CPU, GPU | i5-9500T, UHD Graphics 630 |
| RAM | 8 GB, two 4 GB modules, both slots full |
| Disk | 256 GB SK hynix NVMe, `/dev/nvme0n1`, empty |
| Firmware | UEFI, Secure Boot off, not in Setup Mode, Microsoft keys present |
| TPM | 2.0, Infineon, enabled, activation policy "No prompts" |
| Network | Intel I219-LM, `eno1`, 1 Gb, MAC `bc:e9:2f:86:35:3b` |
| Boot order | NVMe, USB, IPv4 network, IPv6 network |
| Firmware access | `hp-bioscfg` exposes 234 settings; no setup password reported |

The September spec's "13th-gen i3" is wrong and should be corrected.

## Goals

- Install with no screen, keyboard or USB stick attached.
- Disk encryption that unlocks by itself on every boot, with no PIN.
- Updates reach the box nightly and unattended, for nixpkgs and Home Player.
- A bad update rolls itself back. The TV is not left broken.
- Plasma stays available behind Home Player.
- Two accounts: `Vuxna` and `Barn`.

## Non-goals

- Netbird, `ipid` and remote access beyond LAN SSH.
- A snapshot picker in the boot menu. NixOS has no dracut, and generations cover
  the system.
- Booting from the network as normal operation (see Decisions).

## Anti-goals

These would be failures even if everything else worked:

- A box that needs a person after an unattended update or reboot.
- API keys in git, the Nix store or CI.
- Any process on the desktop session gaining root without a password.
- A firmware change that stops the box showing a picture or booting.

## Decisions

### Made by the owner

| Decision | Detail |
|---|---|
| NixOS, not Kubuntu or Ubuntu | Reasons above |
| Network install | No screen and no USB stick |
| TPM unlock with no PIN | |
| Snapshots available to revert to | ZFS already in the layout; the owner offered ZFS, btrfs or bcachefs |
| `Vuxna` logs in automatically and has sudo | |
| `Barn` has no sudo | |
| Simple starter passwords, changed later | |
| Fleet SSH key for access | Same key as `~/.ssh/edholm-key.pub` |
| Unattended updates, nothing done at the box | |
| Sleep is real sleep, and the box wakes itself for updates | Mechanism proposed by the owner: a systemd timer. See Sleep and waking |
| Failed-boot recovery is time-boxed | Use an LTS kernel, try a hardware watchdog with fallback, otherwise accept a screen and keyboard for that case |
| Failures alert in two places | A phone notification through Home Assistant, and a notice on the Home Player home screen |

### Proposed by the designer, open to correction

| Decision | Why |
|---|---|
| **Keep the disk; do not netboot each night** | A nightly RAM boot means a network or server fault takes out the TV, and it loses the installed system's state. It also needs Secure Boot off, because the boot program is unsigned. Staged updates already give a fresh, verified system with rollback. |
| **A new permanent LXC for builds and updates**, named `nixhost` | Replaces `herdr` for this work. Builds nightly, serves the binary cache, and holds the netboot server for rescue. It keeps the owner's idea of a permanent box with a more useful job. |
| **Netboot stays armed for the HTPC's MAC only** | NVMe is first in the boot order, so it does nothing until the disk stops being bootable. Other machines get no answer. It stops working once Secure Boot is on, unless Secure Boot is turned off for the rescue. |
| **API keys in a root-only file on the encrypted disk, not in KDE Wallet** | The backend is a system service that starts before anyone logs in, so a wallet could not serve it. Any program in the session can read an open wallet, and autologin gives it no password. `just secrets htpc` already installs the file from 1Password. |
| **KDE Wallet off for both accounts** | Nothing here depends on it, and it removes every unlock prompt. An app that wants it later can have it turned back on. |
| **Plasma desktop as the default session, Plasma Bigscreen installed as an option** | Home Player is already the TV interface, and the remote setup script targets Plasma. Bigscreen would add a second TV launcher behind the first. It is a choice in the login menu, so trying it is cheap. |
| **Keep ZFS, under LUKS** | Already written. btrfs is the fallback. bcachefs is out of the mainline kernel. |
| **Keep 8 GB of RAM for now** | Builds happen elsewhere. Cap ZFS's cache and add zram. Replacing both modules is an upgrade to consider only if Android apps prove tight. |
| **Reboot only when an update needs it** | Reboots are limited to a night window. A scheduled nightly reboot adds risk with no benefit. |
| **After Power Loss: Power On** | So a power cut does not need someone at the box. |

## Install flow

Each step stops if its check fails. Steps 1 to 3 cannot harm the firmware.
Step 5 can, so it has its own guardrails.

1. **Boot.** `nixhost` serves a netboot image built from this flake to the HTPC's
   MAC only. It replaces the throwaway Pixiecore setup in `~/pxe-spike` on
   `herdr`, whose units and firewall rules are removed once `nixhost` works.
2. **Install.** `nixos-anywhere` from the laptop, where the private `home-player`
   input resolves, writes LUKS, ZFS and the system. A generated recovery
   passphrase is stored in 1Password first. This is the only step that writes
   to the disk.
3. **First boot.** The box stops at the LUKS prompt. Unlock it over initrd SSH
   with the recovery passphrase.
4. **Lanzaboote keys.** Create the keys on the box. Check that the signed boot
   files are in place.
5. **Secure Boot.** Try through `hp-bioscfg` first: clear the keys to reach Setup
   Mode, enrol with `sbctl enroll-keys --microsoft`, enable Secure Boot.
   - **Keep the Microsoft keys.** Firmware components may be signed by them, and
     removing them can leave a machine with no picture.
   - **If the firmware asks for a key press** or refuses the change, stop and ask
     for a screen and keyboard once. Do not retry blind.
6. **TPM enrolment.** Only after Secure Boot is on, because that changes PCR 7:
   `systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7+15:sha256=0000000000000000000000000000000000000000000000000000000000000000`,
   with `tpm2-measure-pcr=yes` in crypttab. PCR 15 stops an attacker from
   swapping in their own root partition to capture the unlock.
7. **Proof.** Reboot twice with nobody typing anything. Confirm SSH comes back,
   Secure Boot is on, and the disk is encrypted. Remove and restore the TPM slot
   only if a test calls for it; the recovery passphrase must still work.
8. **Secrets and identity.** `just secrets htpc`, then the MAC in tfvars and the
   DHCP reservation.

If unlock ever fails, initrd SSH and the recovery passphrase are the way in.
Enrolling after first boot replaces the earlier idea of enrolling from the
installer, because initrd SSH makes it unnecessary and PCR 7 changes anyway.

## System configuration

**Disk.** Extend `nix/hosts/htpc/disko.nix`: ESP unchanged, LUKS on the rest, the
existing `rpool` and datasets inside it. Prefer the `/dev/disk/by-id` name.
Scheduled ZFS snapshots of `home` and `var`: hourly for a day, daily for a week.
`root` and `nix` are not snapshotted, because generations cover them.

**Boot.** `boot.initrd.systemd.enable`, Lanzaboote in place of systemd-boot for
this machine only, initrd SSH with the fleet key. Lanzaboote is a new flake
input. Use a ZFS-compatible LTS kernel so an update cannot fail on ZFS lag.

**Memory.** Cap the ZFS cache at about 1 GiB; enable zram.

**Accounts.**

| Account | Sudo | Login | Password |
|---|---|---|---|
| `default-user` | Passwordless, SSH admin as today | SSH key | None needed |
| `Vuxna` | Yes, **password required** | Automatic at boot | Starter, changeable |
| `Barn` | No | Password, from the login menu | Starter, changeable |

`base.nix` makes all of `wheel` passwordless. On this machine that would give
the auto-logged-in desktop root with no prompt, so `htpc` must require passwords
for `wheel` and grant `default-user` its passwordless rule directly. Other
machines keep today's behaviour. Linux usernames are lowercase by convention;
use `vuxna` and `barn` with the capitalised names as display names.

Starter passwords are set only at account creation, so changes made on the box
survive updates. Their hashes come from 1Password, not plain text in git.

**Desktop.** A new `desktop` role, in place of the unbuilt `kiosk` role: SDDM,
Plasma 6, autologin for `vuxna`, Wallet off, `kdePackages.plasma-bigscreen`
offered as a session. `nixpkgs` carries it at 6.7.4; how it registers as a
session on NixOS has not been checked.

**Home Player.** A new `home-player` role as the September spec describes, with
`homeModules.default` for `vuxna`. The shell starts fullscreen on login over
Plasma. `scripts/kde-remote-setup.sh` is applied through its home-manager option.
Set `roles.android.kioskUser` and `roles.staged-updates.kioskUser` to `vuxna`.

**Barn's session.** `Barn` gets plain Plasma with no Home Player autostart, using
Plasma's switch user, so `vuxna`'s session keeps running. That also keeps the
watchdog's `home-player-shell` check valid. Android starts only for `vuxna`. A
night reboot closes an open `Barn` session; that is accepted.

**Home Player config.** Mirror the live `~/.config/home-player/config.yaml`:
Jellyfin, Sonarr, Radarr, Seerr, game-sync and Sunshine, with secrets as
`${env:...}` references and an updated `secrets.env.tpl`. Leave out `gpu_manager`
unless that branch has merged.

**Firmware.** After Power Loss set to Power On, through `hp-bioscfg`. Wake on LAN
works from S3 and from fully off, so the box can be woken remotely.

## Updates

```
01:30  nixhost: reset to the tracked branch → nix flake update (nixpkgs,
                home-player) → build → check → sign → publish to cache
                → move pointer → force-push the result to nightly/htpc
03:30  HTPC:    read pointer → fetch and verify → stage
                idle: switch, watchdog, roll back if unhealthy
                busy: wait, retry every 15 minutes
                kernel changed: reboot, only inside the night window
```

- **Pull only at night.** The nightly job publishes and stops. It does not wake or
  push to the box, so it needs no WoL step. `just deploy htpc` is the urgent
  path: it pushes the branch to `nixhost`, runs the same nightly job there at
  once, and has the box fetch and activate the result through the `deploy`
  account and `htpc-stage --now`. Signing stays on `nixhost`, and the pointer is
  then the urgent build, so the next night does not revert it.
- **Trigger:** a timer on `nixhost`, not GitLab CI. `/srv/nix-cache` does not
  exist on the runner, the runner has no `/dev/kvm`, and terranse's `origin` is
  on GitHub, so the GitLab path in the September spec was never live. A push no
  longer reaches the TV within minutes; it arrives by the next morning.
  `just deploy htpc` remains for anything urgent.
- **`ship.sh`** is reused to build, sign and publish. A new nightly script does the
  bump first, because checks must pass before the lock bump is committed.
- **Gate:** a failed build or check publishes nothing, so the box keeps running
  what it has. Give `nixhost` `/dev/kvm` if the Proxmox host allows it, so the
  staged-updates VM test runs as part of the gate.
- **Source on the LAN:** `nixhost` hosts bare git repos of terranse and Home Player
  under `/srv/git`, and the laptop pushes to them. The nightly job never writes
  to the branch people push to: each night starts from it as it is (force-pushes
  included) and publishes what it built, lock bump and all, to its own branch
  `nightly/htpc`. `just deploy` warns when the laptop's lock is older than that
  one. No GitHub credential is
  involved, by the owner's direction. GitHub stays an optional mirror. Public flake
  inputs and `cache.nixos.org` still need internet access but no keys, so builds
  stop picking up new upstream versions if the internet is down. A change merged
  only on GitHub reaches the TV once it is pulled and pushed to `nixhost`.
- **Credentials:** `nixhost` holds the cache signing key. All secrets are in the
  `HomeNetwork` vault.
- **Box changes:** add the 03:30 fetch to `staged-updates`, and limit automatic
  switches and reboots to a night window, including the boot-time path. Today's
  policy can do both whenever idle, and a daytime switch would restart the shell
  mid-use. An update missed overnight waits for the next night.
- **Busy check:** Home Player must ship `/system/activity` before unattended
  updates go live. It does not exist yet, and `staged-updates` reads a failed
  request as idle, so nothing currently protects playback. Busy means Jellyfin
  playback or a Moonlight stream. Plasma and Android use are covered by the night
  window, because the backend cannot see them.
- **Mixed bumps:** if the combined bump fails, retry with only `home-player`
  bumped, so a broken nixpkgs does not hold back Home Player. This changes
  `ship.sh --bump`.
- **Health:** set `requireHealthy = true` when Home Player lands.
- **Carried over:** the `deploy` user, trusted signing key and
  `signingPublicKey` gates from the September plan must be closed before install.

## Sleep and waking

Home Player's Sleep button stays a real suspend. A systemd timer with
`WakeSystem=true` wakes the box at 03:30, chosen to avoid the daylight-saving hour. It then fetches, applies any
update and goes back to sleep only if it was asleep before and nobody has started
using it. It must not suspend a box someone is using, and it should not turn the
TV on. Home Player's shell turns the TV on after every resume today
(`shell/src-tauri/src/lib.rs:195`), so it must recognise a scheduled wake.

A box shut down fully, rather than suspended, has no timer running. `nixhost` does
not wake it. It catches up at the next night it is awake or asleep. The build job does not depend on the box
being reachable, and the watchdog's health check must allow for the wake.

Results on this box on 2026-11-05, from the RAM-only NixOS image on kernel 6.18.49:

| Test | Result |
|---|---|
| Sleep type | Real S3 (`deep`) is the default, not s2idle |
| `WakeSystem=true`, relative timer, 3 runs | Woke each time, 80 to 82 s for a 75 s timer; 3 suspends, 0 failures |
| `WakeSystem=true`, `OnCalendar`, the shape this design uses | Woke on time and ran its job 2 s after the target |
| Wake on LAN from S3 | Network answered 6 s after the packet |
| Wake on LAN from fully off | Booted, SSH answered 54 s after the packet |
| Network after each wake | Same address, 1 Gb link |

A service started by a timer
needs absolute paths or a declared `path` on NixOS; an early test job failed with
`date: command not found` although the wake itself worked.

Not covered by these tests, because the box has no screen and no install yet:

- Picture and sound after resume with a TV attached.
- LUKS, ZFS and the TPM across a suspend, and Plasma, Home Player and Waydroid
  resuming.
- One test image logged a missing i915 display firmware file
  (`kbl_dmc_ver1_04.bin`), which affects display power states. Confirm that the
  installed system loads it.

## Failed boots

The watchdog runs inside the booted system, so it cannot catch a kernel hang, a
ZFS import failure or anything else that stops boot. Time-box this:

- Use an LTS kernel.
- Enable the hardware watchdog in the boot path.
- Try automatic fallback to the previous generation under Lanzaboote. It
  supports boot counting; see the result below.

If that is not cleanly possible, stop and record it. A failed boot then needs a
screen and keyboard to pick the previous generation. This is an accepted exception
to the "needs a person" anti-goal. The boot chain does not change for it.

**Result (2026-11-07, `nix/hosts/htpc/boot.nix`).** Lanzaboote supports boot
counting, so this needs no person:

- A new generation's entry gets `+3` tries (`bootCounting.initialTries`). It is
  blessed once `boot-complete.target` is reached, which needs only `sshd`. A
  stuck unit holding back `multi-user.target` would otherwise roll back a
  working generation.
- `panic=10` reboots a panic. The chipset's TCO watchdog (`iTCO_wdt`, 30 s)
  resets a hang. `intel_oc_wdt` is blacklisted, because systemd would
  otherwise pet it instead.
- `htpc-boot-fallback-alert` reports each `+0-*` entry once, through
  `ha-notify`.

Proven on the box at night:

- **Good generation.** It booted unattended, and the TPM unlocked the disk.
  The entry went from `+3` to blessed, and the health check was ok.
- **Crashing generation.** A throwaway generation panicked in the initrd on
  every boot (`echo c > /proc/sysrq-trigger`).
  - 04:23:35: reboot into it.
  - The box crashed three times. These boots leave no journal; the root
    filesystem is never mounted.
  - 04:26:04: SSH was up on the previous generation, and the TPM unlocked the
    disk itself.
  - The bad entry was left as `+0-3`, and the alert service fired.

Two things the test showed:

- **The profile lags behind.** After a fallback,
  `/nix/var/nix/profiles/system` still points at the failed generation. The
  next update or deploy replaces it. By hand, run
  `nix-env --switch-generation` back first.
- **The alert did not reach the phone.** Home Assistant answered 500: "not
  connected to local push notifications". The Pixel 8 app is reachable by
  local push only, so the alert is kept and retried on the next boot. Every
  `ha-notify` alert has this gap.

## Failure alerts

Alert on: no successful nightly build for 3 nights, a rollback, a `bad-revisions`
entry, and a box that has not taken a published update for 3 nights.

- **Phone:** through Home Assistant to the phone named "Pixel 8", needing the
  `HomeAssistant HTPC token` item on `nixhost` and the box.
- **TV:** a small notice on the Home Player home screen, fed from `state.json`.
  This is Home Player work.

## Home Player work

This design needs changes outside terranse:

- `/system/activity`, as above.
- The `state.json` reader and home screen notice.
- The update popup stays later work.

## Risks

- **Secure Boot over `hp-bioscfg` is untested.** Settings have only been read so
  far. A screen and keyboard are the fallback.
- **Android was tested under `cage`, not Plasma.** Window behaviour and
  right-click handling need checking, and sound and real Intel graphics were
  never tested.
- **Bigscreen is untested here.** It returned with Plasma 6.7 and is young.
- **Tracking `nixos-unstable` unattended.** Updates can break things that
  build fine. The watchdog catches an unhealthy backend, but not a blank screen
  with a healthy backend. `requireKioskUnit` narrows this but does not close it.
- **A box with autologin is unlocked when stolen.** Encryption protects a removed
  disk or a disposed machine, not a stolen running system. Accepted by asking for
  no PIN with autologin.
- **Resume with a TV attached is untested.** Check it first after install, because
  sleep is now part of normal daily use.
- **A failed boot that never reaches the initrd** (a broken boot loader or a
  firmware problem) still needs a person. Boot counting covers the kernel,
  the initrd and everything after them. See Failed boots.
- **`nixhost` becomes a dependency for updates only.** If it is down, the TV keeps
  working and stops updating.

## Testing

- Evaluate and build `htpc` with `nix flake check`.
- A VM test for the account rules: `vuxna` needs a password for sudo, `barn` is
  refused, `default-user` is not asked.
- Extend the staged-updates VM test for the fetch time and the reboot window.
- Real hardware: resume with the TV attached, a timed wake that leaves the TV off,
  the proof in step 7, one full overnight update, a deliberately
  failing update that rolls back, and a power-cut restart.

## Left to the builder

Package choice for snapshots, netboot server implementation, the `nixhost`
resources and ID, cache transport, the Android role's naming clean-up, how the
fullscreen shell is started under Plasma, and the order of work.
