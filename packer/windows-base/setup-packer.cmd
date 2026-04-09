@echo off
REM Setup script for Packer provisioning
REM Installs VirtIO serial driver, QEMU guest agent, and configures WinRM
REM This runs from FirstLogonCommands via the OEMDRV CD

set LOG=C:\Windows\Temp\setup-packer.log
echo [%date% %time%] Starting Packer setup >> %LOG%

REM --- Install VirtIO serial driver (needed for QEMU agent communication) ---
echo [%date% %time%] Installing VirtIO serial driver >> %LOG%
pnputil /add-driver D:\vioserial\w11\amd64\*.inf /install >> %LOG% 2>&1
if errorlevel 1 pnputil /add-driver E:\vioserial\w11\amd64\*.inf /install >> %LOG% 2>&1

REM --- Install QEMU guest agent ---
echo [%date% %time%] Installing QEMU guest agent >> %LOG%
if exist "D:\guest-agent\qemu-ga-x86_64.msi" (
    msiexec /i "D:\guest-agent\qemu-ga-x86_64.msi" /qn /norestart >> %LOG% 2>&1
) else if exist "E:\guest-agent\qemu-ga-x86_64.msi" (
    msiexec /i "E:\guest-agent\qemu-ga-x86_64.msi" /qn /norestart >> %LOG% 2>&1
) else (
    echo [%date% %time%] ERROR: qemu-ga-x86_64.msi not found on D: or E: >> %LOG%
)
echo [%date% %time%] Starting QEMU-GA service >> %LOG%
net start QEMU-GA >> %LOG% 2>&1

REM --- Set network to Private (WinRM refuses to configure on Public networks) ---
echo [%date% %time%] Setting network profile to Private >> %LOG%
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private" >> %LOG% 2>&1

REM --- Configure WinRM ---
echo [%date% %time%] Configuring WinRM >> %LOG%
powershell -NoProfile -ExecutionPolicy Bypass -Command "Enable-PSRemoting -Force" >> %LOG% 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value true" >> %LOG% 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "Set-Item WSMan:\localhost\Service\Auth\Basic -Value true" >> %LOG% 2>&1
netsh advfirewall firewall add rule name="WinRM HTTP" dir=in localport=5985 protocol=tcp action=allow >> %LOG% 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "Restart-Service WinRM" >> %LOG% 2>&1

echo [%date% %time%] Packer setup complete >> %LOG%
