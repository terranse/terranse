# windows-lan — bare-metal Windows 11 for LAN parties

One-off (deliberately **not** tofu/Packer-managed) dual-boot of Windows 11 on
`workstation`, prepared inside a throwaway VM that writes onto a raw SATA disk.
Design + rationale: `docs/superpowers/specs/2026-07-16-lan-windows-dualboot-design.md`.

The future *Windows gaming VM* track lives in `packer/windows-gaming` and is a
different animal (virtio, QEMU agent, vGPU). This directory's debloat block is
written to be backported there.

**Disk:** `ata-KINGSTON_SKC6001024G_50026B7785B74D88` (detached from `store`
2026-07-17). Everything below assumes it.

## Phase 0 — prep VM install (remote, no downtime)

```sh
# on workstation, in a copy of this directory
WIN_PASSWORD='...' ./build-unattend-iso.sh

qm create 112 --name win-lan-prep --ostype win11 \
  --machine q35 --bios ovmf --cpu host --cores 8 --sockets 1 \
  --memory 16384 --balloon 0 \
  --efidisk0 local-zfs:1,efitype=4m,pre-enrolled-keys=1 \
  --tpmstate0 local-zfs:1,version=v2.0 \
  --sata0 /dev/disk/by-id/ata-KINGSTON_SKC6001024G_50026B7785B74D88 \
  --ide2 local:iso/Win11_25H2_EnglishInternational_x64_v2.iso,media=cdrom \
  --ide0 local:iso/unattend-lan.iso,media=cdrom \
  --net0 e1000,bridge=vmbr0 \
  --boot order=ide2;sata0 --onboot 0

qm start 112
sleep 4 && qm sendkey 112 spc   # "Press any key to boot from CD" — repeat if missed
```

No virtio, no QEMU agent, no Cloudbase-Init — every device (AHCI disk, e1000
NIC) has a Windows inbox driver so the disk boots identically on real hardware.
Install is fully unattended; watch via the console. When it lands on the
desktop, `setup-lan.ps1` has debloated the machine and opened WinRM (:5985,
user `daniele`) for the rest of the prep: Windows Update, staging installers
(NVIDIA RTX driver for A5000, Intel I210, AMD chipset), Steam + predownloads.

Afterwards: `qm shutdown 112`. Keep the VM around (stopped) for later touch-ups;
`--boot order=sata0` makes it boot straight to Windows next time.

## Phase 1 — bare-metal test boot (at home, before the LAN)

1. **GPU displays on** (kills vGPU/VM 111 until reverted):
   download the NVIDIA *Display Mode Selector Tool* (enterprise portal), then
   `qm stop 111`, unload nvidia/vgpu modules (or `systemctl isolate multi-user`,
   `rmmod nvidia_vgpu_vfio nvidia`), run
   `./displaymodeselector --gpumode physical_display_enabled`, power cycle.
2. **Register the Windows NVRAM entry** (once):
   ```sh
   efibootmgr -c -d /dev/disk/by-id/ata-KINGSTON_SKC6001024G_50026B7785B74D88 \
     -p 1 -L "Windows Boot Manager" -l '\EFI\Microsoft\Boot\bootmgfw.efi'
   efibootmgr        # then efibootmgr -o ... so the Proxmox entry stays FIRST
   ```
3. **Boot Windows once:** `efibootmgr -n <WinID> && reboot` (BootNext is one-shot;
   the reboot after Windows lands back in Proxmox). Monitor on the A5000 DP.
4. In Windows: run the staged NVIDIA driver installer, launch one game, check
   the I210 NIC has link, then run `C:\lan\finalize-for-lan.ps1` (kills prep
   WinRM, verifies BitLocker off / RTC-UTC / no hibernation).

## At the LAN

- Boot Windows: firmware boot-menu key at POST → "Windows Boot Manager",
  or `efibootmgr -n <WinID> && reboot` from a Proxmox shell first.
- Back to Proxmox: just reboot.

## Phase 2 (only if BF6/Faceit-class anti-cheat confirmed) — Secure Boot + fTPM

Do at home, never on-site. BIOS: enable fTPM, enroll factory keys (platform is
in Setup Mode), enable SB. Windows needs nothing. Proxmox needs the signed
shim: `apt install shim-signed shim-helpers-amd64-signed grub-efi-amd64-signed`
then `proxmox-boot-tool reinit` — **verify against the Proxmox Secure Boot wiki
first**. Test-boot both OSes.

## Phase 3 — after the weekend

1. Flip the GPU back: `displaymodeselector --gpumode displayless`, power cycle,
   verify VM 111 + Moonlight work.
2. `efibootmgr` — Windows updates sometimes promote themselves; restore order
   with `efibootmgr -o ...` (Proxmox first).
3. Leave the Kingston as a dormant Windows disk for the next LAN (recommended),
   or wipe it back into the mirror: `zpool attach store
   ata-KINGSTON_SKC6001024G_50026B7785B74DE0 ata-KINGSTON_..._4D88`.

## Gotchas learned the hard way

- **BitLocker auto-encryption is the one thing that can brick this plan** —
  keyed to the prep VM's vTPM, it would demand a recovery key on real
  hardware. `PreventDeviceEncryption=1` is set in specialize; finalize
  re-verifies.
- Activation likely drops on the VM→metal hardware change: weekend watermark,
  or apply a key / MS-account digital license.
- Strict anti-cheat can't be tested in the VM (that's the whole reason this
  exists) — only during the Phase 1 bare-metal boot.
