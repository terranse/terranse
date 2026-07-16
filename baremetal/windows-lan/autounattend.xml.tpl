<?xml version="1.0" encoding="utf-8"?>
<!--
  Bare-metal LAN-party Windows 11 unattend.
  Forked from packer/windows-base/autounattend.xml.tpl — deliberately the
  inverse device story: NO virtio, NO QEMU agent, inbox drivers only, so the
  disk this installs onto boots identically inside the prep VM and on the
  real machine. See docs/superpowers/specs/2026-07-16-lan-windows-dualboot-design.md.

  ${WIN_PASSWORD} is substituted by build-unattend-iso.sh — never commit a real one.
-->
<unattend xmlns="urn:schemas-microsoft-com:unattend"
          xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">

    <!-- WindowsPE: bypass hardware checks, partition disk, select edition -->
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-International-Core-WinPE"
                   processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral" versionScope="nonSxS">
            <SetupUILanguage>
                <UILanguage>en-GB</UILanguage>
            </SetupUILanguage>
            <InputLocale>sv-SE</InputLocale>
            <SystemLocale>en-GB</SystemLocale>
            <UILanguage>en-GB</UILanguage>
            <UserLocale>en-GB</UserLocale>
        </component>

        <component name="Microsoft-Windows-Setup"
                   processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral" versionScope="nonSxS">

            <!-- Hardware-check bypasses kept for robustness (install runs with
                 vTPM + pre-enrolled SB keys, so these should never trigger) -->
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>reg add "HKLM\SYSTEM\Setup\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Path>reg add "HKLM\SYSTEM\Setup\LabConfig" /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <Path>reg add "HKLM\SYSTEM\Setup\LabConfig" /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
            </RunSynchronous>

            <!-- UEFI GPT layout: 1=ESP, 2=MSR, 3=Windows. The ESP on this disk
                 is what efibootmgr registers as "Windows Boot Manager". -->
            <DiskConfiguration>
                <Disk wcm:action="add">
                    <DiskID>0</DiskID>
                    <WillWipeDisk>true</WillWipeDisk>
                    <CreatePartitions>
                        <CreatePartition wcm:action="add">
                            <Order>1</Order>
                            <Size>300</Size>
                            <Type>EFI</Type>
                        </CreatePartition>
                        <CreatePartition wcm:action="add">
                            <Order>2</Order>
                            <Size>16</Size>
                            <Type>MSR</Type>
                        </CreatePartition>
                        <CreatePartition wcm:action="add">
                            <Order>3</Order>
                            <Extend>true</Extend>
                            <Type>Primary</Type>
                        </CreatePartition>
                    </CreatePartitions>
                    <ModifyPartitions>
                        <ModifyPartition wcm:action="add">
                            <Order>1</Order>
                            <PartitionID>1</PartitionID>
                            <Label>System</Label>
                            <Format>FAT32</Format>
                        </ModifyPartition>
                        <ModifyPartition wcm:action="add">
                            <Order>2</Order>
                            <PartitionID>3</PartitionID>
                            <Label>Windows</Label>
                            <Format>NTFS</Format>
                            <Letter>C</Letter>
                        </ModifyPartition>
                    </ModifyPartitions>
                </Disk>
            </DiskConfiguration>

            <ImageInstall>
                <OSImage>
                    <InstallTo>
                        <DiskID>0</DiskID>
                        <PartitionID>3</PartitionID>
                    </InstallTo>
                    <InstallFrom>
                        <MetaData wcm:action="add">
                            <Key>/IMAGE/NAME</Key>
                            <Value>Windows 11 Pro</Value>
                        </MetaData>
                    </InstallFrom>
                </OSImage>
            </ImageInstall>

            <UserData>
                <AcceptEula>true</AcceptEula>
                <FullName>Daniele</FullName>
                <Organization>lanbox</Organization>
                <!-- Generic Pro key: selects the edition only, no activation -->
                <ProductKey>
                    <Key>W269N-WFGWX-YVC9B-4J6C9-T83GX</Key>
                    <WillShowUI>Never</WillShowUI>
                </ProductKey>
            </UserData>
        </component>
    </settings>

    <!-- Specialize: machine policy — dual-boot hygiene + policy-level debloat.
         Deliberately policy toggles only: no component ripping, Defender and
         the Xbox/GameBar stack untouched (anti-cheat + Game Pass friendly). -->
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup"
                   processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral" versionScope="nonSxS">
            <ComputerName>LANBOX</ComputerName>
            <TimeZone>W. Europe Standard Time</TimeZone>
        </component>

        <component name="Microsoft-Windows-Deployment"
                   processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral" versionScope="nonSxS">
            <RunSynchronous>
                <!-- Local account without Microsoft account -->
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <!-- CRITICAL for dual-boot: never auto-BitLocker. The prep VM's
                     vTPM differs from the board's fTPM; auto-encryption keyed to
                     the vTPM would demand a recovery key on real hardware. -->
                <RunSynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Path>reg add "HKLM\SYSTEM\CurrentControlSet\Control\BitLocker" /v PreventDeviceEncryption /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <!-- Both OSes read the RTC as UTC — no clock skew when dual-booting -->
                <RunSynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <Path>reg add "HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <!-- Telemetry to minimum (Pro floor is Required), no feedback nags -->
                <RunSynchronousCommand wcm:action="add">
                    <Order>4</Order>
                    <Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v AllowTelemetry /t REG_DWORD /d 0 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>5</Order>
                    <Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v DoNotShowFeedbackNotifications /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <!-- No preinstalled partner apps, suggestions, or lockscreen ads -->
                <RunSynchronousCommand wcm:action="add">
                    <Order>6</Order>
                    <Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableWindowsConsumerFeatures /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>7</Order>
                    <Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableSoftLanding /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>8</Order>
                    <Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableCloudOptimizedContent /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <!-- Advertising ID off machine-wide -->
                <RunSynchronousCommand wcm:action="add">
                    <Order>9</Order>
                    <Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo" /v DisabledByGroupPolicy /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <!-- Widgets / news-and-interests off -->
                <RunSynchronousCommand wcm:action="add">
                    <Order>10</Order>
                    <Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Dsh" /v AllowNewsAndInterests /t REG_DWORD /d 0 /f</Path>
                </RunSynchronousCommand>
                <!-- Copilot + Recall off -->
                <RunSynchronousCommand wcm:action="add">
                    <Order>11</Order>
                    <Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" /v TurnOffWindowsCopilot /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>12</Order>
                    <Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v DisableAIDataAnalysis /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <!-- No P2P Windows Update distribution (be a good LAN citizen) -->
                <RunSynchronousCommand wcm:action="add">
                    <Order>13</Order>
                    <Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" /v DODownloadMode /t REG_DWORD /d 0 /f</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>

    <!-- OOBE: skip everything, local admin, autologon (single-user gaming box) -->
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup"
                   processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral" versionScope="nonSxS">
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideLocalAccountScreen>true</HideLocalAccountScreen>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Work</NetworkLocation>
                <ProtectYourPC>3</ProtectYourPC>
            </OOBE>

            <UserAccounts>
                <LocalAccounts>
                    <LocalAccount wcm:action="add">
                        <Name>daniele</Name>
                        <Group>Administrators</Group>
                        <Password>
                            <Value>${WIN_PASSWORD}</Value>
                            <PlainText>true</PlainText>
                        </Password>
                    </LocalAccount>
                </LocalAccounts>
            </UserAccounts>

            <AutoLogon>
                <Enabled>true</Enabled>
                <Username>daniele</Username>
                <Password>
                    <Value>${WIN_PASSWORD}</Value>
                    <PlainText>true</PlainText>
                </Password>
                <LogonCount>100</LogonCount>
            </AutoLogon>

            <FirstLogonCommands>
                <!-- Stage scripts from whichever drive letter the unattend CD got -->
                <SynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <CommandLine>cmd /c mkdir C:\lan 2>nul &amp; for %i in (D E F G) do if exist %i:\setup-lan.ps1 copy /y %i:\*.ps1 C:\lan\</CommandLine>
                    <Description>Copy LAN setup scripts to C:\lan</Description>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <CommandLine>powershell -NoProfile -ExecutionPolicy Bypass -File C:\lan\setup-lan.ps1</CommandLine>
                    <Description>Per-user debloat, power settings, WinRM for prep</Description>
                </SynchronousCommand>
            </FirstLogonCommands>
        </component>

        <component name="Microsoft-Windows-International-Core"
                   processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral" versionScope="nonSxS">
            <InputLocale>sv-SE</InputLocale>
            <SystemLocale>en-GB</SystemLocale>
            <UILanguage>en-GB</UILanguage>
            <UserLocale>en-GB</UserLocale>
        </component>
    </settings>
</unattend>
