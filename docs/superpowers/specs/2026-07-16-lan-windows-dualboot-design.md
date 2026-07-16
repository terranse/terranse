# LAN-party Windows 11 dual-boot on `workstation` — design

**Date:** 2026-07-16
**Status:** approved (Daniele, 2026-07-16)
**Scope:** one physical machine (`workstation`, Gigabyte MC12-LE0, Ryzen 9 5900X, RTX A5000, Proxmox VE 8.4)

## Goal

Boot bare-metal Windows 11 on the workstation for a LAN-party weekend — needed for
anti-cheat titles that refuse VMs — without disturbing the Proxmox install, which
stays the default OS. Prep everything possible remotely, ahead of time.

## Facts that shaped the design

- Host boots **systemd-boot via proxmox-boot-tool (uefi mode)** — there is no GRUB.
  ESP `8133-F6F2` on `nvme2n1p2` (rpool disk).
- **Secure Boot disabled, platform in Setup Mode; no TPM device** (fTPM off in BIOS).
- The **RTX A5000 is in displayless mode** (shows as `3D controller`; required for
  vGPU on Ampere) — its DisplayPorts are dead until flipped back with NVIDIA's
  `displaymodeselector`. Only other display is the ASPEED BMC VGA (2D).
- BMC exists (IPMI 2.0 fw 12.61) but has **no LAN IP configured** → no remote iKVM.
- `store` pool: empty 2×1TB Kingston SKC600 mirror (82 MiB used, incl. an unused
  thick 800G NTFS zvol `store/data`). One disk can be detached with no data risk.
- terranse already has `packer/windows-base` + `packer/windows-gaming` templates
  with an autounattend lineage (virtio + QEMU agent + WinRM — VM-shaped choices).
- ISO on host is 23H2 (end of servicing); catalog wants
  `Win11_25H2_EnglishInternational_x64_v2.iso` (never uploaded).

## Decisions (from design Q&A)

| Question | Decision |
|---|---|
| Anti-cheat level | Likely EAC/BattlEye (bare metal suffices). BF6 possible → Secure Boot + fTPM as a **deferrable contingency**, done at home if BF6 firms up. |
| Display at LAN | Flip the A5000 to `physical_display_enabled` with displaymodeselector for the weekend; flip back after. vGPU / VM 111 is down while flipped. |
| Windows disk | Detach one Kingston (`ata-KINGSTON_SKC6001024G_50026B7785B74D88`, sdc) from `store`; pool continues single-disk. Disk is wiped. |
| Install method | **VM-staged**: throwaway Proxmox VM writes a normal UEFI/GPT Windows onto the raw physical disk; zero host downtime; one bare-metal test boot at home validates it. |
| IaC | Bare-metal prep is a committed one-off artifact in terranse (`baremetal/windows-lan/`), NOT a tofu/Packer-managed object. The future "Windows gaming VM role" continues from `packer/windows-gaming` separately; debloat block is written to be backportable there. |

## Architecture

### Prep VM (throwaway, VMID 112 `win-lan-prep`)

Deliberately inverse of the Packer templates — every device must have a Windows
**inbox** driver so the same install boots on real hardware:

- `q35` + OVMF (4m efidisk) + **vTPM 2.0** (satisfies Win11 install; real fTPM comes
  later via BIOS if needed) + `cpu: host` (same 5900X either way)
- **`sata0: /dev/disk/by-id/ata-KINGSTON_SKC6001024G_50026B7785B74D88`** — raw whole
  disk, AHCI. Windows' inbox storahci driver covers both QEMU AHCI and the board's.
- **NIC: `e1000`** (Intel inbox driver). Bare metal has Intel I210 — also inbox/WU.
- **No virtio anywhere, no QEMU guest agent, no Cloudbase-Init.** Nothing VM-flavored
  persists on disk for anti-cheat to sniff or to dangle driverless on real hardware.
- ISO: Win11 25H2 EnglishInternational + a small `unattend.iso` (second cdrom)
  carrying `autounattend.xml` — Windows Setup scans all removable media for it.

### autounattend.xml (`baremetal/windows-lan/`)

Forked from `packer/windows-base/autounattend.xml.tpl`, with:

- UEFI/GPT layout (ESP 300M / MSR / C:) — unchanged; GPT+MS-signed chain means the
  install is **Secure-Boot-ready from day one** even though SB is off now.
- Local admin account, autologon (gaming box), OOBE fully skipped.
- **BitLocker device-encryption prevented** (`HKLM\SYSTEM\CurrentControlSet\Control\BitLocker
  → PreventDeviceEncryption=1`, set in specialize) — critical: auto-BitLocker keyed
  to the vTPM would demand a recovery key on real hardware.
- **`RealTimeIsUniversal=1`** + TimeZone `W. Europe Standard Time` (dual-boot clock).
- `powercfg /h off` (kills hibernation *and* Fast Startup → no dirty NTFS state
  between OSes), High Performance power plan.
- **Debloat, policy-level only** ("minimal but not suspiciously so" — no component
  ripping, Defender untouched, Xbox/GameBar stack kept for Game Pass titles):
  telemetry to minimum, advertising ID off, consumer features / suggested apps /
  lockscreen ads off, Bing-in-Start off, Copilot off, Recall off, widgets off,
  OneDrive uninstalled, Teams/News/Weather/Clipchamp etc. deprovisioned.
- **WinRM enabled during prep only** (drive driver/Steam installs remotely), with a
  `finalize-for-lan.ps1` on the desktop that disables WinRM/autologon-if-desired and
  re-checks: BitLocker off, RTC-UTC set, drivers present.
- Keeps the LabConfig TPM/SB bypasses (harmless; robustness if fTPM stays off).

### Preloaded content (via WinRM/console while still a VM)

Windows Update; NVIDIA **RTX/professional driver** for A5000 (installer on disk, run
on first bare-metal boot — the vGPU *guest* driver is wrong for bare metal, so no
GPU is attached to the prep VM); Intel I210 driver; AMD chipset driver; Steam +
login + predownload library (~890G free). Strict anti-cheat titles can only be
*tested* bare-metal.

### Boot flow (no bootloader changes at all)

Windows lives on its own disk with its own ESP. systemd-boot won't chainload a
foreign ESP and doesn't need to — UEFI NVRAM does the work:

- Register once: `efibootmgr -c -d /dev/disk/by-id/ata-KINGSTON..._4D88 -p 1
  -L "Windows Boot Manager" -l '\EFI\Microsoft\Boot\bootmgfw.efi'`, then reorder so
  the Proxmox entry stays first.
- **Default = Proxmox** (BootOrder unchanged). Boot Windows via one-shot
  `efibootmgr -n <WinID> && reboot` from the host, or the firmware boot-menu key.
  After Windows, a plain reboot lands back in Proxmox.
- Known gotcha: Windows updates sometimes promote Windows Boot Manager to the top
  of BootOrder — post-weekend checklist includes `efibootmgr -o` restore.

### GPU flip (bracketing the weekend)

1. Download NVIDIA Display Mode Selector Tool (enterprise portal — same account as
   vGPU/nvlts).
2. Before LAN: stop VM 111, unload vGPU modules, `displaymodeselector --gpumode
   physical_display_enabled`, power cycle. DisplayPorts live; vGPU dead.
3. After LAN: same dance back to displayless; VM 111 resumes.

### Secure Boot + fTPM contingency (only if BF6/Faceit-class games confirmed)

Do **at home with time to spare**, never on-site:

1. BIOS: enable fTPM; enroll factory keys (platform already in Setup Mode); enable SB.
2. Windows: nothing (MS-signed chain; BitLocker stays off so the vTPM→fTPM swap is a
   non-event).
3. Proxmox: migrate to signed shim — `apt install shim-signed
   shim-helpers-amd64-signed grub-efi-amd64-signed`, `proxmox-boot-tool reinit`
   (verify exact steps against the Proxmox Secure Boot wiki at execution time).
4. Test-boot both OSes with SB on.

### Post-weekend

Flip GPU displayless → verify VM 111 + Moonlight; check/restore BootOrder; leave the
Kingston as a dormant Windows disk for the next LAN (recommended — `store` doesn't
miss it), or `zpool attach` it back, wiping Windows.

## Phases

- **Phase 0 (remote, now):** detach+wipe Kingston; obtain 25H2 ISO; write
  `baremetal/windows-lan/` artifacts (autounattend, unattend-ISO build script,
  runbook); create VM 112; run unattended install; in-VM prep (updates, drivers
  staged, debloat verification, Steam).
- **Phase 1 (home, ~1h, before LAN):** displaymodeselector flip; register NVRAM
  entry; bare-metal test boot — NVIDIA driver install, one game launch, NIC check;
  reboot lands in Proxmox; run `finalize-for-lan.ps1`.
- **Phase 2 (optional):** Secure Boot + fTPM contingency.
- **Phase 3 (post-LAN):** GPU flip back; BootOrder check; VM 111 verify.

## Risks / accepted trade-offs

- **Activation** likely drops on VM→metal (hardware hash change): weekend watermark,
  or a key / MS-account digital license fixes it. Accepted.
- Anti-cheat titles unverifiable until Phase 1's bare-metal boot — which is exactly
  why Phase 1 happens at home.
- While the GPU is display-enabled, the Moonlight/VM-111 stack is offline.
- `store` runs non-redundant until (if ever) re-mirrored; it holds nothing today.
- 23H2 ISO fallback (if 25H2 can't be fetched) works but adds a feature-update cycle.

## Out of scope

- Finishing the **Windows gaming VM role** (`packer/windows-gaming` + tofu wiring) —
  separate track; will inherit this spec's debloat block via backport.
- BMC LAN/iKVM configuration (would help future remote ops; not needed for this).
- game-sync / home-player integration of the Windows library.
