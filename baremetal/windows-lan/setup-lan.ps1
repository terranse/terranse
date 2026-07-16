# First-logon setup for the LAN-party bare-metal Windows install.
# Ran automatically by autounattend FirstLogonCommands. Idempotent-ish; safe to re-run.
# Policy-level debloat only — Defender and the Xbox/GameBar stack are untouched.

Start-Transcript -Path C:\lan\setup-lan.log -Append

# --- Power: no hibernation (also kills Fast Startup -> clean NTFS for dual-boot),
# --- High Performance plan
powercfg /hibernate off
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c

# --- Per-user debloat (HKCU of the daniele account) ---
$cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
New-Item -Path $cdm -Force | Out-Null
foreach ($v in 'SilentInstalledAppsEnabled','SystemPaneSuggestionsEnabled','SoftLandingEnabled',
               'SubscribedContent-338388Enabled','SubscribedContent-338389Enabled',
               'SubscribedContent-353694Enabled','SubscribedContent-353696Enabled') {
    Set-ItemProperty -Path $cdm -Name $v -Value 0 -Type DWord
}
# Advertising ID + tailored experiences off for this user
New-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' -Force | Out-Null
Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' -Name Enabled -Value 0 -Type DWord
New-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' -Force | Out-Null
Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' -Name TailoredExperiencesWithDiagnosticDataEnabled -Value 0 -Type DWord
# No Bing/web results in Start search
New-Item -Path 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' -Force | Out-Null
Set-ItemProperty -Path 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' -Name DisableSearchBoxSuggestions -Value 1 -Type DWord
New-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Force | Out-Null
Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Name BingSearchEnabled -Value 0 -Type DWord
Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Name CortanaConsent -Value 0 -Type DWord
# Taskbar: no widgets, no chat
$adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
Set-ItemProperty -Path $adv -Name TaskbarDa -Value 0 -Type DWord -ErrorAction SilentlyContinue
Set-ItemProperty -Path $adv -Name TaskbarMn -Value 0 -Type DWord -ErrorAction SilentlyContinue

# --- OneDrive: uninstall (gaming box syncs nothing) ---
foreach ($od in "$env:SystemRoot\SysWOW64\OneDriveSetup.exe", "$env:SystemRoot\System32\OneDriveSetup.exe") {
    if (Test-Path $od) { & $od /uninstall; break }
}

# --- Deprovision consumer bloat (keeps: Store, Xbox*, GameBar, Calculator,
# --- Photos, Terminal, Notepad, Media Player, Snipping Tool) ---
$bloat = @(
    'Clipchamp.Clipchamp', 'Microsoft.BingNews', 'Microsoft.BingWeather',
    'Microsoft.BingSearch', 'Microsoft.Todos', 'MSTeams', 'MicrosoftTeams',
    'Microsoft.GetHelp', 'Microsoft.Getstarted', 'Microsoft.MicrosoftOfficeHub',
    'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.People',
    'Microsoft.PowerAutomateDesktop', 'Microsoft.WindowsMaps',
    'Microsoft.WindowsFeedbackHub', 'Microsoft.OutlookForWindows',
    'Microsoft.Windows.DevHome', 'Microsoft.MicrosoftStickyNotes'
)
foreach ($name in $bloat) {
    Get-AppxPackage -AllUsers -Name $name -ErrorAction SilentlyContinue |
        Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    Get-AppxProvisionedPackage -Online |
        Where-Object DisplayName -eq $name |
        Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
}

# --- WinRM: PREP ONLY, so the install can be driven remotely while still a VM.
# --- finalize-for-lan.ps1 disables all of this before the LAN party.
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private
Enable-PSRemoting -Force
Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $true
Set-Item WSMan:\localhost\Service\Auth\Basic -Value $true
netsh advfirewall firewall add rule name="WinRM HTTP (prep)" dir=in localport=5985 protocol=tcp action=allow
Restart-Service WinRM

Set-Content -Path C:\lan\setup-done.txt -Value (Get-Date -Format o)
Stop-Transcript
