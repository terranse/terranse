# Run as admin right before packing the machine for the LAN party.
# Closes the prep-only remote access and verifies the dual-boot invariants.

$ErrorActionPreference = 'Continue'
Write-Host "=== finalize-for-lan ===" -ForegroundColor Cyan

# --- Close prep-only WinRM access ---
Disable-PSRemoting -Force
Stop-Service WinRM
Set-Service WinRM -StartupType Disabled
netsh advfirewall firewall delete rule name="WinRM HTTP (prep)" | Out-Null
Write-Host "[ok] WinRM disabled"

# --- Verify dual-boot invariants ---
$fail = 0

$blv = Get-BitLockerVolume -MountPoint C: -ErrorAction SilentlyContinue
if ($blv -and $blv.ProtectionStatus -ne 'Off') {
    Write-Host "[FAIL] BitLocker protection is ON — run: manage-bde -off C:" -ForegroundColor Red; $fail++
} else { Write-Host "[ok] BitLocker off" }

$rtc = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' -ErrorAction SilentlyContinue).RealTimeIsUniversal
if ($rtc -ne 1) { Write-Host "[FAIL] RealTimeIsUniversal not set — clocks will skew vs Proxmox" -ForegroundColor Red; $fail++ }
else { Write-Host "[ok] RTC-is-UTC set" }

if (Test-Path "$env:SystemRoot\System32\hiberfil.sys") {
    Write-Host "[FAIL] hibernation still enabled — run: powercfg /h off" -ForegroundColor Red; $fail++
} else { Write-Host "[ok] hibernation/Fast Startup off" }

$gpu = Get-CimInstance Win32_VideoController | Where-Object Name -match 'NVIDIA'
if ($gpu) { Write-Host "[ok] NVIDIA GPU driver active: $($gpu.Name), $($gpu.DriverVersion)" }
else { Write-Host "[WARN] no NVIDIA display driver active (expected before the bare-metal driver install)" -ForegroundColor Yellow }

$tpm = Get-Tpm -ErrorAction SilentlyContinue
Write-Host ("[info] TPM present: {0}, ready: {1}" -f $tpm.TpmPresent, $tpm.TpmReady)
Write-Host ("[info] SecureBoot: {0}" -f $(try { Confirm-SecureBootUEFI } catch { 'unsupported/off' }))

if ($fail -eq 0) { Write-Host "ALL CHECKS PASSED — ready for the LAN" -ForegroundColor Green }
else { Write-Host "$fail CHECK(S) FAILED — fix before packing" -ForegroundColor Red }
