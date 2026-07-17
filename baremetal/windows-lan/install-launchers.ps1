# Install game launchers silently from official sources. Run elevated.
# Steam is installed by the staging flow already; -IncludeSteam re-runs it.
param([switch]$IncludeSteam)

Start-Transcript C:\lan\launchers.log -Append
New-Item -ItemType Directory -Force -Path C:\lan | Out-Null

if ($IncludeSteam) {
    Invoke-WebRequest -Uri 'https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe' -OutFile C:\lan\SteamSetup.exe -UseBasicParsing
    Start-Process -Wait C:\lan\SteamSetup.exe -ArgumentList '/S'
}

# Epic Games Launcher (MSI -> proper silent install)
Invoke-WebRequest -Uri 'https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi' -OutFile C:\lan\EpicInstaller.msi -UseBasicParsing
Start-Process -Wait msiexec -ArgumentList '/i','C:\lan\EpicInstaller.msi','/qn','/norestart'

# Battle.net (no official /S; --lang + --installpath runs unattended)
Invoke-WebRequest -Uri 'https://downloader.battle.net/download/getInstaller?os=win&installer=Battle.net-Setup.exe' -OutFile C:\lan\BattleNetSetup.exe -UseBasicParsing
Start-Process -Wait C:\lan\BattleNetSetup.exe -ArgumentList '--lang=enUS','--installpath="C:\Program Files (x86)\Battle.net"'

foreach ($p in 'C:\Program Files (x86)\Steam\steam.exe',
               'C:\Program Files (x86)\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe',
               'C:\Program Files (x86)\Battle.net\Battle.net Launcher.exe') {
    Write-Host ("{0}: {1}" -f $p, (Test-Path $p))
}
Stop-Transcript
