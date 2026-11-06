# HTPC Install and Nightly Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install NixOS with TPM-unlocked LUKS and ZFS on the HP mini PC with no screen attached, run Home Player over Plasma, and keep it updated every night with no human step.

**Architecture:** terranse declares the machine and a new `nixhost` LXC. `nixhost` builds and signs a system nightly and serves it from a binary cache. The HTPC wakes itself, fetches, activates through the existing `staged-updates` policy, then returns to sleep. Home Player gains an activity endpoint, a home screen notice and a quiet scheduled wake.

**Tech Stack:** NixOS flakes, disko, nixos-anywhere, Lanzaboote, systemd-cryptenroll, ZFS, home-manager, Pixiecore, Plasma 6; Python/FastAPI and Rust/Leptos/Tauri in Home Player; pytest and `runNixOSTest`.

**Spec:** `docs/superpowers/specs/2026-11-05-htpc-install-and-updates-design.md`, which changes `docs/superpowers/specs/2026-09-06-htpc-nixos-design.md`.

## Global Constraints

- HTPC MAC `bc:e9:2f:86:35:3b`; disk `nvme-SK_hynix_BC511_HFM256GDJTNI-82A0A_CY05N062410305M16`; NIC driver `e1000e`, interface `eno1`.
- Linux usernames `vuxna` and `barn`; display names `Vuxna` and `Barn`.
- `vuxna`: autologin, in `wheel`, sudo requires a password. `barn`: not in `wheel`. `default-user`: passwordless sudo, SSH only.
- Times, in `Europe/Stockholm`: nightly build `01:30`, HTPC wake `03:30`, activation window `03:30` to `05:30`. These avoid the daylight-saving hour.
- ZFS cache cap `1073741824` bytes. Snapshots of `home` and `var`: hourly for 24, daily for 7.
- TPM policy: PCRs `7+15`, with PCR 15 sealed to all zeros and `tpm2-measure-pcr=yes` in crypttab.
- `sbctl enroll-keys --microsoft`. Never enrol without the Microsoft keys.
- Alert after 3 nights without a successful build or a taken update, and on any rollback or `bad-revisions` entry.
- No secret in git, the Nix store or a command line. Secrets come from 1Password through `just secrets`.
- Do not change other machines' sudo behaviour. `base.nix` stays as it is for them.
- **Nothing writes to the HTPC's disk or firmware before Task 12, and Task 12 needs the owner's explicit go-ahead.**

- The phone is named "Pixel 8". Its service is `notify.mobile_app_pixel_8`, confirmed against Home Assistant before Task 9.

## Review Focus

1. Someone presses the remote during a night wake: the box must stay awake and the TV must turn on, not suspend under them. Test in Task 8.
2. The cache is unreachable, or a fetch or activation fails during a night wake: the box must still go back to sleep. Test in Task 8.
3. The shell dies mid-film and never reports `stopped`: `/system/activity` must not stay busy forever. Test in Task 1.
4. Home Assistant is down when an alert fires: the update flow must carry on and not fail its unit. Test in Task 9.
5. A real user wake within minutes of the scheduled time: a wake outside the tolerance turns the TV on, and input inside it is caught by item 1. Test in Task 2.

---

## Working Setup

- terranse work: branch `feat/htpc-install`, worktree `~/Repos/terranse-wt-htpc`. Do not run Ansible from that worktree; it matches no hosts and still exits 0.
- Home Player work: branch `feat/htpc-night-updates`, worktree `~/Repos/home-player-wt-htpc`.
- Check after each commit that it landed on the feature branch, because subagents have run git in the original repo root before.
- Web wasm tests need `GECKODRIVER=$(nix path-info nixpkgs#geckodriver)/bin/geckodriver`. Backend tests run with `uv run pytest` from `backend/`.
- herdr's login shell is fish and OPNsense's is csh, so pipe scripts to `bash -s` or `sh -s`. OPNsense is `ssh -p 2223 root@opnsense.edholm.cc`.
- Merging and pushing either repo needs the owner's approval. Task 5 onward can pin the `home-player` input to the feature branch until then.

## Secrets

All in 1Password vault `HomeNetwork`, generated without being shown to anyone. Read them only through a pipe, `op read` into a file or stdin, never onto a command line and never into a report.

| Item | Field | Used by |
|---|---|---|
| `HTPC LUKS recovery` | `password` | Task 12 |
| `HTPC Vuxna`, `HTPC Barn` | `password` (plain; hash in a pipe with `mkpasswd -s`, stored nowhere) | Task 4, Task 12 |
| `HTPC cache signing key` | `password` (secret), `public_key` | Task 7, Task 11 |
| `HomeAssistant HTPC token` | `password` | Task 9, Task 10 |

## Human Gates

The owner does these. Stop and ask when a task reaches one.

| Gate | Needed by |
|---|---|
| Approval to create `nixhost` and to push branches to it | Task 11 |
| Go-ahead to write the disk and firmware | Task 12 |
| A screen and keyboard, only if the firmware refuses Secure Boot changes | Task 12 |

---

## Part 1: Home Player

### Task 1: `/system/activity` endpoint

**Files:**
- Create: `backend/home_player/activity.py`
- Modify: `backend/home_player/main.py` (`report_playback` near line 851, new route beside `/health` near line 339)
- Test: `backend/tests/test_activity.py`

**Interfaces:**
- Produces: `GET /system/activity` returning `{"busy": bool, "reasons": list[str]}`, with reasons from `"playback"` and `"stream"`. `staged-updates` already reads `.busy`.
- Produces: `class PlaybackActivity` with `note(event: str, session: str, now: float) -> None` and `active(now: float) -> bool`.

- [ ] **Step 1: Write failing tests** with an injected clock and a stub Sunshine host:

```python
def test_idle_when_nothing_has_happened(client): assert client.get("/system/activity").json() == {"busy": False, "reasons": []}
def test_started_playback_is_busy(...): # POST report event=started -> busy True, reasons ["playback"]
def test_paused_playback_is_still_busy(...): # progress with is_paused=True -> busy True
def test_stopped_playback_is_idle(...): # started then stopped -> busy False
def test_silent_session_expires(...): # started, clock +301s, no progress -> busy False
def test_running_stream_is_busy(...): # _stream app set and Sunshine busy() True -> reasons ["stream"]
def test_unreachable_sunshine_is_not_busy(...): # busy() False -> busy False
def test_report_counts_even_if_upstream_fails(...): # Jellyfin raises httpx.HTTPError -> still busy
```

- [ ] **Step 2: Run them.** `uv run pytest tests/test_activity.py -v`. Expected: FAIL, route missing.
- [ ] **Step 3: Implement.** Track sessions by `play_session_id`, expire at `SESSION_STALE_SECONDS = 300`, and call `note` before forwarding upstream. Check the player's progress interval is well under 300 s. Stream busy uses the `_sunshine_host.busy` call and host at `main.py:511`, and only when `_stream["app"]` is set.
- [ ] **Step 4: Run** the new tests and the full backend suite. Expected: PASS.
- [ ] **Step 5: Commit** `feat(backend): report whether the TV is in use`.

### Task 2: Stay quiet on a scheduled wake

Today `shell/src-tauri/src/lib.rs:195` turns the TV on after every resume, which would light the TV at 03:30.

**Files:**
- Modify: `shell/src-tauri/src/resume.rs`, `shell/src-tauri/src/lib.rs:195`

**Interfaces:**
- Consumes: file `/run/htpc-night/scheduled-wake`, one Unix epoch integer, written by Task 8. Override path with `HOMEPLAYER_SCHEDULED_WAKE_FILE`.
- Produces: `pub fn scheduled_wake(now: i64, scheduled: Option<i64>) -> bool` in `resume.rs`, with `SCHEDULED_WAKE_TOLERANCE_SECONDS = 180`.

- [ ] **Step 1: Write failing unit tests** in `resume.rs`:

```rust
assert!(scheduled_wake(1000, Some(1000)));
assert!(scheduled_wake(1120, Some(1000)));   // late by 2 min
assert!(!scheduled_wake(1000 + 181, Some(1000)));   // a real user wake afterwards
assert!(!scheduled_wake(1000 - 181, Some(1000)));
assert!(!scheduled_wake(1000, None));        // no file: every other machine
```

- [ ] **Step 2: Run** `cargo test -p home-player-shell resume`. Expected: FAIL. Check the package name in `shell/src-tauri/Cargo.toml`.
- [ ] **Step 3: Implement,** and skip the `tv/on` post in the `resume::watch` callback when it returns true. A missing or unparsable file reads as `None`.
- [ ] **Step 4: Run** tests. Expected: PASS.
- [ ] **Step 5: Commit** `feat(shell): leave the TV off on a scheduled wake`.

### Task 3: Update notice on the home screen

**Files:**
- Modify: `backend/home_player/main.py`, `backend/home_player/config.py`
- Create: `web/src/components/update_notice.rs`
- Modify: `web/src/components/mod.rs`, `web/src/api.rs`, `web/src/lib.rs` (mount on the home screen)
- Test: `backend/tests/test_update_status.py`, a wasm test beside the component

**Interfaces:**
- Consumes: `/var/lib/htpc-update/state.json` from Task 9, with `reason`, `age_seconds`, `build_age_seconds`, `rolled_back_at`.
- Produces: `GET /system/update-status` returning `{"notice": str | null}`. Config `system.update_state_path`, default `/var/lib/htpc-update/state.json`.

- [ ] **Step 1: Write failing backend tests:** missing file, unreadable file and invalid JSON all give `notice: null`; `reason: "bad"` gives `"Latest update was rolled back"`; `build_age_seconds >= 259200` gives `"No new updates for 3 nights"`; `age_seconds >= 259200` gives `"Update waiting for 3 nights"`; a fresh state gives null.
- [ ] **Step 2: Run** them. Expected: FAIL.
- [ ] **Step 3: Implement** the route, then a small unfocusable notice that fetches on load and renders nothing when null. It must not take remote-control focus or move the rows.
- [ ] **Step 4: Run** backend and wasm tests. Expected: PASS.
- [ ] **Step 5: Commit** `feat(web): show when updates have stopped`.

---

## Part 2: terranse configuration

### Task 4: Accounts and desktop

**Files:**
- Create: `nix/roles/desktop.nix`, `nix/hosts/htpc/accounts.nix`, `nix/tests/htpc-accounts.nix`
- Modify: `nix/roles/default.nix`, `nix/machines.nix`, `nix/hosts/htpc/default.nix`, `flake.nix` (checks), `justfile`
- Modify: `tofu/deployments/edholm/configurations.tfvars:369` (`mac = "bc:e9:2f:86:35:3b"`)

**Interfaces:**
- Produces: `roles.desktop.{enable, autologinUser : str, bigscreen : bool}`.
- Produces: `just htpc-passwords`, which reads `op://HomeNetwork/HTPC Vuxna/password` and `op://HomeNetwork/HTPC Barn/password`, hashes each with `mkpasswd -s` in a pipe, and feeds `sudo chpasswd -e` over SSH.

- [ ] **Step 1: Write the failing VM test** `htpc-accounts`, importing `accounts.nix`:

```python
machine.fail("su - vuxna -c 'sudo -n true'")     # password required
machine.succeed("id -nG vuxna | grep -w wheel")
machine.fail("id -nG barn | grep -w wheel")
machine.fail("su - barn -c 'sudo -n true'")
machine.succeed("su - default-user -c 'sudo -n true'")
```

- [ ] **Step 2: Run** `nix build .#checks.x86_64-linux.htpc-accounts`. Expected: FAIL.
- [ ] **Step 3: Implement accounts.** `security.sudo.wheelNeedsPassword = true` on this host only, with a `NOPASSWD: ALL` `extraRules` entry for `default-user`. Accounts have no password in Nix; `users.mutableUsers` stays true. `Barn` has no Home Player autostart.
- [ ] **Step 4: Implement `desktop`:** SDDM on Wayland, `services.desktopManager.plasma6`, autologin, and KDE Wallet off for both accounts by writing `Enabled=false` to `kwalletrc`. With `bigscreen`, add `kdePackages.plasma-bigscreen`, and register its session through `services.displayManager.sessionPackages` if it does not appear on its own. Add a `system.build.toplevel` assertion that a `plasma-bigscreen` wayland session file exists.
- [ ] **Step 5: Run** the test and `nix build .#checks.x86_64-linux.machine-htpc`. Expected: PASS.
- [ ] **Step 6: Commit** `feat(nix): give the HTPC its accounts and Plasma`.

### Task 5: Home Player on the box

**Files:**
- Create: `nix/roles/home-player.nix`
- Modify: `flake.nix`, `flake.lock`, `nix/roles/default.nix`, `nix/machines.nix`, `nix/hosts/htpc/secrets.env.tpl` (create if absent)

**Interfaces:**
- Consumes: `/system/activity` from Task 1; `services.home-player` and `homeModules.default` from the Home Player flake.
- Produces: `roles.home-player.{enable, kioskUser}`. Input `home-player`, URL `git+ssh://git@github.com/yarcod/home-player` for now, using the laptop's key. Task 11 changes it to the LAN repo on `nixhost`.

- [ ] **Step 1: Write the failing eval checks** in `nix/tests/htpc-eval.nix`, a new check that throws on any false value: backend enabled; `environmentFile == "/var/lib/home-player-secrets/env"` as a string; `wakeOnLan.enable`; `roles.android.kioskUser == "vuxna"`; `roles.staged-updates.kioskUser == "vuxna"`; `roles.staged-updates.requireHealthy`; home-manager declares `home-player-shell` for `vuxna` and not for `barn`.
- [ ] **Step 2: Run** `nix build .#checks.x86_64-linux.htpc-eval`. Expected: FAIL.
- [ ] **Step 3: Implement.** Mirror the provider sections of `~/.config/home-player/config.yaml` in `services.home-player.settings`: Jellyfin, Sonarr, Radarr, Seerr, game-sync, Sunshine and Home Assistant, each secret as `${env:NAME}`. Leave out `gpu_manager`. Copy `op://` references, not values, into the template. Set `services.home-player-shell.configureKde = true`. Android starts for `vuxna` only: scope the `waydroid-session` user unit with a `ConditionUser=vuxna`.
- [ ] **Step 4: Run** the eval check and `machine-htpc`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(nix): run Home Player on the HTPC`.

### Task 6: Encrypted disk and signed boot

**Files:**
- Modify: `nix/hosts/htpc/disko.nix`, `nix/hosts/htpc/hardware.nix`, `nix/hosts/htpc/default.nix`, `flake.nix`, `flake.lock`, `nix/tests/htpc-eval.nix`
- Create: `nix/hosts/htpc/boot.nix`

**Interfaces:**
- Produces: LUKS device `cryptroot` on disko partition `luks` (`/dev/disk/by-partlabel/disk-main-luks`); initrd SSH on port `2222` with host key `/etc/secrets/initrd/ssh_host_ed25519_key`; PKI bundle `/var/lib/sbctl`. Input `lanzaboote`.

- [ ] **Step 1: Add failing eval assertions:** `cryptroot` crypttab options contain `tpm2-device=auto` and `tpm2-measure-pcr=yes`; `boot.initrd.systemd.enable`; `boot.lanzaboote.enable`; `boot.loader.systemd-boot.enable == false`; `e1000e` in `boot.initrd.availableKernelModules`; `boot.initrd.network.ssh.enable`, with the fleet key; ARC cap in `boot.kernelParams` or `extraModprobeConfig`; `zramSwap.enable`; `hardware.enableRedistributableFirmware`; kernel not newer than ZFS supports, using the default LTS `linuxPackages`.
- [ ] **Step 2: Run** the check. Expected: FAIL.
- [ ] **Step 3: Implement.** Keep the ESP. Put `rpool` and its datasets inside a LUKS partition with `passwordFile = "/tmp/htpc-luks.key"`, which nixos-anywhere supplies. Use the by-id disk path. Add a snapshot tool with the retention in Global Constraints for `rpool/home` and `rpool/var` only. `lib.mkForce false` the `metal` profile's systemd-boot here, not in the profile. Make `sbctl` available.
- [ ] **Step 4: Build the disk script.** Run `nix build .#nixosConfigurations.htpc.config.system.build.diskoScript`. Expected: builds, and the script opens LUKS before creating `rpool`.
- [ ] **Step 5: Run** `htpc-eval` and `machine-htpc`. Expected: PASS.
- [ ] **Step 6: Commit** `feat(nix): encrypt the HTPC's disk and sign its boot`.

### Task 7: Activation window and urgent deploys

**Files:**
- Modify: `nix/roles/staged-updates.nix`, `nix/tests/staged-updates.nix`, `nix/roles/base.nix` (signing key), `nix/machines.nix`, `scripts/ship.sh`, `justfile`
- Create: `nix/hosts/htpc/deploy.nix`

**Interfaces:**
- Produces: `roles.staged-updates.activationWindow`, `null` or `{ start = "03:30"; end = "05:30"; }`, default `null`.
- Produces: `htpc-update --force-idle` also bypasses the window. `htpc-stage --now <path>` staged by `just deploy`.
- Produces: `ship.sh --no-push` (publish and stop, no WoL or SSH) and `ship.sh --now` (push path, activates immediately).

- [ ] **Step 1: Write failing subtests** in the staged-updates VM test, with `activationWindow` set around a controllable clock using `date -s`:

```python
with subtest("outside the window nothing activates, even when idle"): ...
with subtest("inside the window an idle box activates"): ...
with subtest("--force-idle ignores the window"): ...
with subtest("boot-time fetch stages but honours the window"): ...
```

- [ ] **Step 2: Run** `nix build .#checks.x86_64-linux.staged-updates`. Expected: new subtests FAIL.
- [ ] **Step 3: Implement** the check in `htpc-update` after the bad-revisions check, writing state `outside-window`. Handle a window on one side of midnight only, and assert that at evaluation.
- [ ] **Step 4: Close the September gates.** Declare `deploy` on this host, not in `wheel`, with the CI public key. Set `signingPublicKey` and `base.nix`'s `trusted-public-keys` to the output of `op read "op://HomeNetwork/HTPC cache signing key/public_key"`, which is public and belongs in git. Set `cacheUrl = "http://nixhost.edholm.cc:8080"` and the HTPC's window.
- [ ] **Step 5: Implement `ship.sh` flags,** and make `just deploy` pass `--now`. Run `shellcheck scripts/ship.sh`.
- [ ] **Step 6: Run** the VM test and `machine-htpc`. Expected: PASS.
- [ ] **Step 7: Commit** `feat(nix): only activate unattended updates at night`.

### Task 8: Night wake and return to sleep

**Files:**
- Create: `nix/roles/night-updates.nix`, `nix/tests/night-updates.nix`
- Modify: `nix/roles/default.nix`, `nix/machines.nix`, `flake.nix`, `nix/roles/staged-updates.nix` (expose fetch for reuse)

**Interfaces:**
- Consumes: `htpc-update-fetch`, `/system/activity`, the backend's `POST /home-assistant/tv/on`.
- Produces: `roles.night-updates.{enable, wakeTime = "03:30"}`.
- Produces: `/run/htpc-night/scheduled-wake`, world-readable epoch of the next timer elapse, written by a system-sleep `pre` hook. `/run/htpc-night/resumed-at`, written by the `post` hook. `/var/lib/htpc-update/resuspend-after-boot`, which survives the reboot.
- Produces: `htpc-night-decide`, a pure script reading env `TIMED`, `INPUT_SEEN`, `BUSY`, `REBOOT_PENDING` and printing one of `suspend`, `stay-awake`, `tv-on`, `keep-marker`.

- [ ] **Step 1: Write failing tests** in `night-updates`:

```python
with subtest("timed wake, nothing else: back to sleep"): assert decide(TIMED=1) == "suspend"
with subtest("input seen: TV on, stays awake"): assert decide(TIMED=1, INPUT_SEEN=1) == "tv-on"
with subtest("busy: stays awake"): assert decide(TIMED=1, BUSY=1) == "stay-awake"
with subtest("reboot pending: marker kept for after boot"): assert decide(TIMED=1, REBOOT_PENDING=1) == "keep-marker"
with subtest("the box was already awake: never suspends"): assert decide(TIMED=0) == "stay-awake"
with subtest("failed or unreachable fetch still returns to sleep"):
    # stop the fake cache, start htpc-night.service, assert it asked to suspend and did not fail
with subtest("marker after reboot suspends once the watchdog is done"): ...
```

Replace `systemctl suspend` with an overridable command, so the VM records the request and stays up.

- [ ] **Step 2: Run** `nix build .#checks.x86_64-linux.night-updates`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - `htpc-night.timer`: `OnCalendar=*-*-* 03:30:00`, `WakeSystem=true`, `AccuracySec=1s`, `Persistent=false`.
  - `htpc-night.service`, oneshot with `restartIfChanged = false` and `X-StopOnRemoval = false`, for the reason documented on `htpc-update`; `TimeoutStartSec = "30min"`.
  - `TIMED` is true when `resumed-at` is within 180 s of the start, or the marker exists after a boot.
  - Run `libinput debug-events` for the whole run to set `INPUT_SEEN`; ignore device-added lines.
  - The fetch runs without `set -e` around it, so failure still reaches the decision.
  - Use absolute paths or declared `path`: on this box a timer job failed with `date: command not found`.
  - Do not touch the TV on a timed wake. Call `tv/on` only for `tv-on`.
  - Disable any Plasma auto-suspend, because Home Player's Sleep owns suspend.
- [ ] **Step 4: Run** tests and `machine-htpc`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(nix): wake the HTPC at night to update it`.

### Task 9: Failure alerts on the box

**Files:**
- Create: `scripts/ha-notify.sh`, `nix/roles/update-alerts.nix`
- Modify: `nix/roles/default.nix`, `nix/roles/staged-updates.nix` (`write_state` fields), `nix/machines.nix`, `nix/tests/staged-updates.nix`, `nix/hosts/htpc/secrets.env.tpl`

**Interfaces:**
- Produces: `ha-notify.sh <title> <message>`, reading `HA_URL`, `HA_TOKEN`, `HA_NOTIFY_SERVICE`. It always exits 0, with a 10 s limit, and logs a failure.
- Produces: `state.json` gains `build_age_seconds`, from the epoch in `<cacheUrl>/pointers/<host>.last-success` (null if unreachable), and `rolled_back_at`.
- Produces: `roles.update-alerts.{enable, notifyService}`.

- [ ] **Step 1: Write failing subtests:** a rollback calls the notifier once (fake HA records it); an already-reported bad revision does not notify again; `age_seconds >= 259200` notifies once per stale period; **an unreachable HA leaves the alert unit successful and the activation result unchanged**; `state.json` contains the new fields, null when the cache is unreachable.
- [ ] **Step 2: Run** them. Expected: FAIL.
- [ ] **Step 3: Implement** a daily check service in the 03:30 run, deduplicated by a stamp file in `/var/lib/htpc-update`. The token comes from the env file via `EnvironmentFile`, so it is never on a command line.
- [ ] **Step 4: Run** tests. Expected: PASS.
- [ ] **Step 5: Commit** `feat(nix): tell someone when updates stop`.

### Task 10: Nightly build script

**Files:**
- Create: `scripts/nightly.sh`, `tests/test_nightly.py`

**Interfaces:**
- Consumes: `ship.sh htpc --no-push`, `ha-notify.sh`.
- Produces: `nightly.sh <machine>`, run from a clean checkout. On success writes `<cache>/pointers/<machine>.last-success` with the current epoch.

- [ ] **Step 1: Write failing pytest tests** using stub `nix`, `git` and `ship.sh` on `PATH`, which log calls and fail on demand:

```python
def test_all_inputs_pass_ships_and_commits(...): # commit message names all inputs; ship called once
def test_failed_all_bump_retries_home_player_only(...): # lock restored, then update home-player only, ship called
def test_both_fail_publishes_nothing(...): # no ship, last-success unchanged, exit nonzero
def test_alerts_only_after_three_nights(...): # last-success 2 nights old: no notifier; 3 nights old: notifier called once
def test_build_failure_after_bump_never_commits(...): # no git commit before checks pass
def test_no_changes_still_records_success(...): # last-success updated, no empty commit
def test_dirty_checkout_refuses(...): # exit nonzero before any update
def test_no_kvm_skips_only_vm_tests_loudly(...): # logs a skip, other checks still run
```

- [ ] **Step 2: Run** `uv run pytest tests/test_nightly.py -v`. Expected: FAIL.
- [ ] **Step 3: Implement.** `git pull --ff-only` from the bare repo on `nixhost`, then `nix flake update` for all inputs, build `.#checks.x86_64-linux.*` by enumerating as `.gitlab-ci.yml` does, commit `chore(nix): nightly bump [skip ci]`, push, and call `ship.sh`. The `--bump` flag in `ship.sh` stays unused, because the check must run before the commit.
- [ ] **Step 4: Run** tests and `shellcheck scripts/nightly.sh`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(nix): build and publish the HTPC's system nightly`.

### Task 11: `nixhost` LXC

**Files:**
- Create: `nix/hosts/nixhost/default.nix`, `nix/roles/update-host.nix`, `nix/netboot.nix`
- Modify: `nix/machines.nix`, `nix/roles/default.nix`, `flake.nix`, `tofu/deployments/edholm/configurations.tfvars`, `nix/installer.nix`, `justfile`

**Interfaces:**
- Consumes: `scripts/nightly.sh`, `scripts/prune-cache.sh`.
- Produces: `roles.update-host.{enable, netbootMac, buildTime = "01:30"}`. Cache served at `http://nixhost.edholm.cc:8080` from `/srv/nix-cache`. Bare repos `git@nixhost.edholm.cc:/srv/git/terranse.git` and `git@nixhost.edholm.cc:/srv/git/home-player.git`, with the fleet key for the laptop and a key made on first boot for the nightly job's own access.
- Produces: flake package `htpc-netboot` (kernel, initrd and init path); `just install-htpc`.

- [ ] **Step 1: Write failing tests.** A VM test `update-host`: `curl` of a file under `/srv/nix-cache` returns 200; `GET /v1/boot/bc:e9:2f:86:35:3b` on the local API returns kernel and initrd; any other MAC returns 404; only ports 8080 and the PXE set are open; the nightly timer is at `01:30` with `Persistent=true`; a `git` user can clone and push `/srv/git/terranse.git` over SSH with a test key and has no shell otherwise.
- [ ] **Step 2: Run** `nix build .#checks.x86_64-linux.update-host`. Expected: FAIL.
- [ ] **Step 3: Implement.** Copy the shape of the `herdr` block in tfvars with `cores = 8`, `memory = 16384`, `disk_size = "200G"`, `ostype = "nixos"`, `provision = "none"`. Move the shared rescue settings from `installer.nix` into a module both images import. Serve the MAC-restricted API as `~/pxe-spike/api.py` proves on herdr, with Pixiecore in API mode and `--dhcp-no-bind`. Try `/dev/kvm` passthrough; if the Proxmox host refuses, leave it out, since Task 10 skips VM tests loudly.
- [ ] **Step 4: Run** the test and `machine-nixhost`. Expected: PASS.
- [ ] **Step 5: Deploy.** With the owner's approval: `just push-lxc-template nixhost`, `tofu apply` for this container and the HTPC's reservation only, then `just secrets nixhost`. Add a `nixhost` remote in both repos on the laptop and push both branches. Change the `home-player` input to `git+ssh://git@nixhost.edholm.cc/srv/git/home-player.git` and re-lock. Run `ssh default-user@nixhost.edholm.cc sudo systemctl start nixhost-nightly`. Expected: a pointer at `http://nixhost.edholm.cc:8080/pointers/htpc`, signed: `nix path-info --sigs --store http://nixhost.edholm.cc:8080 <path>` lists the key.
- [ ] **Step 6: Commit** `feat(nix): add nixhost to build and serve the HTPC's updates`.

---

## Part 3: Real hardware

Steps here touch the real box, so stop on any surprise. Do not retry firmware changes blind.

### Task 12: Install

**Files:**
- Modify: `justfile`, `docs/superpowers/specs/2026-09-06-htpc-nixos-design.md` (add "superseded in part" and fix the CPU), `docs/todo.md`

**Interfaces:**
- Consumes: Tasks 4 to 7 and 11.

- [ ] **Step 1: Get the owner's go-ahead** to erase the disk and change firmware.
- [ ] **Step 2: Boot from `nixhost`.** Stop `herdr`'s throwaway units and rules first, because two PXE servers would race. Power-cycle the box. Expected: SSH as root at `.193`, hostname `htpc-installer`, disk still blank by `lsblk -f`.
- [ ] **Step 3: Install.** `just install-htpc`, which reads the recovery passphrase from 1Password into a temporary file, generates the initrd host key as an extra file, runs `nixos-anywhere --build-on local --disk-encryption-keys /tmp/htpc-luks.key ...`, and removes the file. The passphrase is never on a command line. Expected: the box reboots.
- [ ] **Step 4: Unlock.** `ssh -p 2222 root@htpc.edholm.cc systemd-tty-ask-password-agent`, then the passphrase. Expected: `ssh default-user@htpc.edholm.cc` works, and `findmnt /` shows `rpool/root`, with `cryptroot` beneath it in `lsblk`.
- [ ] **Step 5: Create Lanzaboote keys.** `sudo sbctl create-keys`, rebuild. Expected: `sbctl verify` shows the signed files on the ESP.
- [ ] **Step 6: Secure Boot.** Load `hp-bioscfg`, read `Clear Secure Boot keys`, set it to Enable, and reboot through initrd unlock. Expected: `sbctl status` shows Setup Mode on. If it does not, or the firmware waits for a key press, **stop and ask for a screen and keyboard**.
- [ ] **Step 7: Enrol.** `sudo sbctl enroll-keys --microsoft`, then set `Configure Legacy Support and Secure Boot` to the Secure Boot enabled entry in its `possible_values`. Reboot through initrd unlock. Expected: `bootctl status` shows Secure Boot enabled.
- [ ] **Step 8: Enrol the TPM.** The command is in the spec, install step 6. Expected: `systemd-cryptenroll /dev/disk/by-partlabel/disk-main-luks` lists both `tpm2` and `password`.
- [ ] **Step 9: Prove it.** Reboot twice with nobody typing. Expected: SSH returns both times with no initrd prompt, and `journalctl -b` shows TPM unlock. Then confirm the recovery passphrase with `cryptsetup open --test-passphrase`.
- [ ] **Step 10: Finish.** `After Power Loss` to Power On; `just secrets htpc /var/lib/home-player-secrets/env root`; `just htpc-passwords`. Expected: backend `/health` returns ok, and `systemctl --user -M vuxna@ is-active home-player-shell` reports active.
- [ ] **Step 11: Commit** `docs: record the HTPC install`, including the September spec corrections.

### Task 13: Acceptance on the TV

The owner runs the viewing checks, with the TV attached.

- [ ] **Step 1: Picture.** Sound and picture after boot, and after Home Player's Sleep then a remote wake. Expected: both return, and the TV turns on.
- [ ] **Step 2: Display firmware.** `journalctl -k | grep -i dmc`. Expected: the i915 file loaded, with no "failed with error -2".
- [ ] **Step 3: Encrypted resume.** After Step 1: ZFS healthy with `zpool status`, Home Player playing, and network back.
- [ ] **Step 4: Timed wake.** Sleep the box with the timer temporarily a few minutes ahead. Expected: the TV stays off, the box updates or finds nothing to do, and it returns to sleep.
- [ ] **Step 5: Remote during a timed wake.** Expected: TV on, and it does not suspend.
- [ ] **Step 6: Real overnight update,** with a published change. Expected: the morning generation matches the pointer, the box is asleep, and no alert fires.
- [ ] **Step 7: Bad update.** Publish a generation whose backend fails. Expected: rollback, `bad-revisions` entry, phone alert and home screen notice. Then publish a good one and confirm it lands.
- [ ] **Step 8: Android under Plasma.** App opens fullscreen, the window closes on exit, right click, and sound. Fix what fails in `nix/roles/android.nix`.
- [ ] **Step 9: Barn.** Switch user from Plasma and back. Expected: `vuxna`'s shell stays active, so the watchdog stays valid; `barn` has no Android, no Home Player and no sudo.
- [ ] **Step 10: Bigscreen.** Choose it at login and try it. If the owner prefers it, change the default session in `roles.desktop`.
- [ ] **Step 11: Power cut.** Pull mains and restore. Expected: the box starts and unlocks by itself.
- [ ] **Step 12: Clean up.** Remove `~/pxe-spike` from herdr. Expected: `systemctl status pxe-api pxe-pixiecore pxe-capture` finds no units, and `sudo iptables -S nixos-fw | grep pxe-spike` is empty.
- [ ] **Step 13: Commit** any fixes as their own `fix:` commits.

### Task 14: Automatic fallback from a failed boot (time-boxed to one session)

A [2026 talk lists boot counting among Lanzaboote's recent work](https://cfp.all-systems-go.io/all-systems-go-2026/talk/QDB7AL/), but whether the pinned version supports it is unconfirmed, and NixOS's own `systemd-boot` option [has been reverted before](https://git.uninsane.org/colin/nixpkgs/commit/b01852a162216ff5521c43254986fe3048a35f56).

**Files:**
- Modify: `nix/hosts/htpc/boot.nix`, `flake.lock`, the spec's Failed boots section

- [ ] **Step 1: Hardware watchdog.** Enable `systemd.settings.Manager.RuntimeWatchdogSec` with the module matched to `iTCO_wdt`, check the option name in the pinned nixpkgs. Expected on the box: `wdctl` shows it armed.
- [ ] **Step 2: Check support** in the pinned Lanzaboote source. If there is none and it would need a boot chain change, go to Step 5.
- [ ] **Step 3: Implement boot counting** with a `boot-complete.target` tied to the existing health check, keeping Secure Boot and the TPM policy unchanged.
- [ ] **Step 4: Prove it** on the box with a generation that panics in the initrd, with a screen available in case. Expected: after the tries, the previous generation boots, TPM unlock still works, and an alert fires.
- [ ] **Step 5: Record the result in the spec.** If unsupported, state that a failed boot needs a screen and keyboard to pick the previous generation.
- [ ] **Step 6: Commit** `feat(nix): fall back from a failed boot` or `docs: record that failed boots need a person`.
