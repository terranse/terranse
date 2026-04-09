<?xml version="1.0" encoding="utf-8"?>
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

            <!-- Bypass Windows 11 hardware requirements (TPM, SecureBoot, RAM) -->
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

            <!-- UEFI GPT layout: ESP (FAT32) + MSR + Windows.
                 Partition numbers: 1=ESP, 2=MSR, 3=Windows. Cloudbase-Init
                 and the diskpart RunOnce fallback in windows-base.pkr.hcl
                 both extend partition 3 on first boot of a clone. -->
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
                <FullName>Packer</FullName>
                <Organization>Packer</Organization>
                <ProductKey>
                    <Key>W269N-WFGWX-YVC9B-4J6C9-T83GX</Key>
                    <WillShowUI>Never</WillShowUI>
                </ProductKey>
            </UserData>
        </component>
    </settings>

    <!-- Specialize: computer name, timezone, and OOBE bypass -->
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup"
                   processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral" versionScope="nonSxS">
            <ComputerName>WinBase</ComputerName>
            <TimeZone>UTC</TimeZone>
        </component>

        <!-- Allow local account creation without Microsoft Account (BypassNRO) -->
        <component name="Microsoft-Windows-Deployment"
                   processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral" versionScope="nonSxS">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>

    <!-- OOBE: skip all screens, create packer user, enable WinRM -->
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
                        <Name>packer</Name>
                        <Group>Administrators</Group>
                        <Password>
                            <Value>${password}</Value>
                            <PlainText>true</PlainText>
                        </Password>
                    </LocalAccount>
                </LocalAccounts>
            </UserAccounts>

            <AutoLogon>
                <Enabled>true</Enabled>
                <Username>packer</Username>
                <Password>
                    <Value>${password}</Value>
                    <PlainText>true</PlainText>
                </Password>
                <LogonCount>5</LogonCount>
            </AutoLogon>

            <FirstLogonCommands>
                <!-- Install VirtIO serial driver (required for QEMU agent communication) -->
                <SynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <CommandLine>cmd /c pnputil /add-driver D:\vioserial\w11\amd64\*.inf /install</CommandLine>
                    <Description>Install VirtIO serial driver from D:</Description>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <CommandLine>cmd /c pnputil /add-driver E:\vioserial\w11\amd64\*.inf /install</CommandLine>
                    <Description>Fallback: install VirtIO serial driver from E:</Description>
                </SynchronousCommand>
                <!-- Install QEMU guest agent from VirtIO ISO (for Packer IP discovery) -->
                <SynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <CommandLine>cmd /c msiexec /i D:\guest-agent\qemu-ga-x86_64.msi /qn /norestart</CommandLine>
                    <Description>Install QEMU guest agent from D:</Description>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <Order>4</Order>
                    <CommandLine>cmd /c msiexec /i E:\guest-agent\qemu-ga-x86_64.msi /qn /norestart</CommandLine>
                    <Description>Fallback: install QEMU guest agent from E:</Description>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <Order>5</Order>
                    <CommandLine>cmd /c net start QEMU-GA</CommandLine>
                    <Description>Start QEMU guest agent</Description>
                </SynchronousCommand>
                <!-- Set network to Private (WinRM refuses Public networks) -->
                <SynchronousCommand wcm:action="add">
                    <Order>6</Order>
                    <CommandLine>powershell -NoProfile -Command "Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private"</CommandLine>
                    <Description>Set network to Private</Description>
                </SynchronousCommand>
                <!-- Configure WinRM for Packer provisioning -->
                <SynchronousCommand wcm:action="add">
                    <Order>7</Order>
                    <CommandLine>powershell -NoProfile -Command "Enable-PSRemoting -Force"</CommandLine>
                    <Description>Enable PS remoting</Description>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <Order>8</Order>
                    <CommandLine>powershell -NoProfile -Command "Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value true"</CommandLine>
                    <Description>Allow unencrypted WinRM</Description>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <Order>9</Order>
                    <CommandLine>powershell -NoProfile -Command "Set-Item WSMan:\localhost\Service\Auth\Basic -Value true"</CommandLine>
                    <Description>Enable basic auth</Description>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <Order>10</Order>
                    <CommandLine>cmd /c netsh advfirewall firewall add rule name="WinRM HTTP" dir=in localport=5985 protocol=tcp action=allow</CommandLine>
                    <Description>Open WinRM port</Description>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <Order>11</Order>
                    <CommandLine>powershell -NoProfile -Command "Restart-Service WinRM"</CommandLine>
                    <Description>Restart WinRM</Description>
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
