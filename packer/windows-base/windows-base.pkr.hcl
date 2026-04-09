# Packer template for Windows Base VM
#
# Creates a minimal Windows 11 cloud-init enabled template:
# - OVMF/UEFI boot (required for modern GPU passthrough with Resizable BAR)
# - VirtIO drivers for performance
# - Cloudbase-Init for cloud-init support
# - RDP enabled
# - QEMU guest agent
# - No gaming software (Steam, Sunshine, Chocolatey packages)
#
# Prerequisites:
#   - Windows 11 ISO uploaded to Proxmox (cannot auto-download)
#   - VirtIO drivers ISO is auto-downloaded from catalog

packer {
  required_plugins {
    proxmox = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

# Proxmox connection
variable "proxmox_url" {
  type        = string
  description = "Proxmox API URL"
}

variable "proxmox_username" {
  type        = string
  description = "Proxmox API username"
}

variable "proxmox_token" {
  type        = string
  sensitive   = true
  description = "Proxmox API token"
}

variable "proxmox_node" {
  type        = string
  default     = "proxmox"
  description = "Proxmox node name"
}

# OS catalog
variable "os_catalog" {
  type = map(object({
    iso_url            = string
    iso_checksum       = string
    iso_file           = string
    os_type            = string
    cloud_img_url      = string
    cloud_img_checksum = string
  }))
  description = "OS catalog mapping family-version to ISO details"
}

variable "os_family" {
  type        = string
  default     = "windows"
  description = "OS family"
}

variable "os_version" {
  type        = string
  default     = "11"
  description = "OS version"
}

variable "virtio_iso_url" {
  type        = string
  default     = ""
  description = "URL for VirtIO drivers ISO (auto-download)"
}

variable "virtio_iso_checksum" {
  type        = string
  default     = ""
  description = "Checksum for VirtIO drivers ISO"
}

variable "storage_pool" {
  type        = string
  default     = "local-lvm"
  description = "Proxmox storage pool for VM disks and EFI"
}

variable "vm_name" {
  type        = string
  default     = ""
  description = "Override VM template name (defaults to {os_family}-{os_version}-base)"
}

variable "winrm_username" {
  type        = string
  default     = "packer"
  description = "WinRM username for provisioning"
}

variable "winrm_password" {
  type        = string
  sensitive   = true
  description = "WinRM/local-account password (from 1Password)"
}

# Resolve ISO from catalog
locals {
  os_key         = "${var.os_family}-${var.os_version}"
  os             = var.os_catalog[local.os_key]
  use_virtio_url = var.virtio_iso_url != ""
  vm_name        = var.vm_name != "" ? var.vm_name : "${var.os_family}-${var.os_version}-base"
  autounattend = templatefile("${path.root}/autounattend.xml.tpl", {
    password = var.winrm_password
  })
}

source "proxmox-iso" "windows-base" {
  # Proxmox connection
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_username
  token                    = var.proxmox_token
  node                     = var.proxmox_node
  insecure_skip_tls_verify = true

  # VM settings — no vm_id, Proxmox auto-assigns
  vm_name              = local.vm_name
  template_description = "Windows ${var.os_version} Base Template - Built by Packer"

  # Hardware (OVMF/UEFI — required for modern NVIDIA GPU passthrough with ReBAR.
  # LabConfig registry keys in autounattend bypass TPM/SecureBoot checks.)
  cores    = 4
  memory   = 16384
  cpu_type = "host"
  os       = local.os.os_type
  bios     = "ovmf"
  machine  = "q35"

  # Explicit boot order — OVMF needs the Windows ISO first since the sata0
  # disk is initially empty. The ISO is attached on sata3 (see boot_iso
  # below) because OVMF/q35 can't reliably boot from the legacy IDE bus
  # (ide.1) that Packer's default `boot_iso { }` would pick.
  boot = "order=sata3;sata0"

  # EFI disk for UEFI boot. pre_enrolled_keys=false keeps SecureBoot disabled
  # (autounattend bypass requires SecureBoot off during install).
  efi_config {
    efi_storage_pool  = var.storage_pool
    efi_type          = "4m"
    pre_enrolled_keys = false
  }

  # Primary disk (SATA — built-in Windows drivers, no VirtIO needed for disk)
  disks {
    type         = "sata"
    disk_size    = "64G"
    storage_pool = var.storage_pool
    format       = "raw"
  }

  # Network (e1000 — built-in Windows drivers, no VirtIO needed during install)
  network_adapters {
    model  = "e1000"
    bridge = "vmbr0"
  }

  # Windows ISO — resolved from catalog (pre-uploaded, uses iso_file).
  # Attached as SATA (not the default IDE) because OVMF/q35 struggles to
  # enumerate/boot the legacy IDE bus; SATA gets an AHCI controller that
  # OVMF drivers handle natively. Index 3 avoids the sata0 disk and the
  # sata1/sata2 additional_iso_files below.
  boot_iso {
    type     = "sata"
    index    = "3"
    iso_file = local.os.iso_file
    unmount  = true
  }

  # VirtIO drivers — auto-downloaded or pre-uploaded
  additional_iso_files {
    type         = "sata"
    index        = 1
    iso_url      = local.use_virtio_url ? var.virtio_iso_url : null
    iso_checksum = local.use_virtio_url ? var.virtio_iso_checksum : null
    iso_file     = local.use_virtio_url ? null : "local:iso/virtio-win.iso"
    unmount      = true
  }

  # Autounattend via SATA CD — rendered inline from a template so we can
  # inject the 1Password-generated password.
  additional_iso_files {
    type             = "sata"
    index            = 2
    cd_content = {
      "autounattend.xml" = local.autounattend
      "setup-packer.cmd" = file("${path.root}/setup-packer.cmd")
    }
    cd_label         = "OEMDRV"
    iso_storage_pool = "local"
  }

  # Boot settings — OVMF shows a TianoCore splash, then the Windows UEFI
  # ISO's "Press any key to boot from CD or DVD..." prompt only lasts about
  # 1 second. A single spacebar is nearly impossible to time correctly.
  # Instead, spam spacebars across a wide window to guarantee one lands in
  # the prompt window.
  boot_command = [
    "<spacebar><wait1s><spacebar><wait1s><spacebar><wait1s><spacebar>",
    "<wait1s><spacebar><wait1s><spacebar><wait1s><spacebar><wait1s><spacebar>",
    "<wait1s><spacebar><wait1s><spacebar><wait1s><spacebar><wait1s><spacebar>",
  ]
  boot_wait = "5s"

  # WinRM connection (configured by autounattend)
  communicator   = "winrm"
  winrm_username = var.winrm_username
  winrm_password = var.winrm_password
  winrm_timeout  = "60m"
  winrm_insecure = true
  winrm_use_ssl  = false

  # Cloud-init via Cloudbase-Init
  cloud_init              = true
  cloud_init_storage_pool = var.storage_pool

  # QEMU guest agent
  qemu_agent = true
}

build {
  sources = ["source.proxmox-iso.windows-base"]

  # Wait for Windows to finish setup
  provisioner "powershell" {
    inline = [
      "Write-Host 'Waiting for Windows to settle...'",
      "Start-Sleep -Seconds 30"
    ]
  }

  # QEMU guest agent is already installed by autounattend.xml from VirtIO ISO

  # Install Cloudbase-Init for cloud-init support
  provisioner "powershell" {
    inline = [
      "$cloudbaseUrl = 'https://cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi'",
      "Invoke-WebRequest -Uri $cloudbaseUrl -OutFile C:\\Windows\\Temp\\CloudbaseInit.msi",
      "Start-Process -FilePath msiexec.exe -ArgumentList '/i', 'C:\\Windows\\Temp\\CloudbaseInit.msi', '/qn', '/norestart' -Wait",
      "Remove-Item C:\\Windows\\Temp\\CloudbaseInit.msi -Force"
    ]
  }

  # Configure Cloudbase-Init so that ExtendVolumesPlugin grows the Windows
  # partition (C:) to fill the disk on first boot of a clone. Without this,
  # a VM cloned and resized to 256G still shows only the template's 64G
  # inside Windows Explorer. With UEFI/GPT layout Windows sits on
  # partition 3 (ESP=1, MSR=2, Windows=3).
  provisioner "powershell" {
    inline = [
      "$conf = 'C:\\Program Files\\Cloudbase Solutions\\Cloudbase-Init\\conf\\cloudbase-init.conf'",
      "$content = Get-Content $conf -Raw",
      "if ($content -notmatch 'volumes_to_extend') { Add-Content -Path $conf -Value \"`nvolumes_to_extend=3`n\" }",
      "$unattendConf = 'C:\\Program Files\\Cloudbase Solutions\\Cloudbase-Init\\conf\\cloudbase-init-unattend.conf'",
      "if (Test-Path $unattendConf) {",
      "  $u = Get-Content $unattendConf -Raw",
      "  if ($u -notmatch 'volumes_to_extend') { Add-Content -Path $unattendConf -Value \"`nvolumes_to_extend=3`n\" }",
      "}"
    ]
  }

  # Run-once fallback: on first boot of a clone, extend the Windows
  # partition to fill the resized disk. Windows Setup automatically creates
  # a WinRE Recovery partition AFTER partition 3, which blocks a plain
  # extend — so we delete it first, then resize partition 3 to the max
  # supported size. Cloudbase-Init's ExtendVolumesPlugin can't do this on
  # its own (it only handles contiguous free space), which is why we need
  # this PowerShell fallback running from a SYSTEM-level RunOnce entry.
  #
  # The script is written one Add-Content line at a time to avoid
  # PowerShell here-strings (which collide with Packer's script wrapper)
  # and nested-quote gymnastics.
  provisioner "powershell" {
    inline = [
      "New-Item -ItemType Directory -Force -Path C:\\ProgramData\\packer | Out-Null",
      "$p = 'C:\\ProgramData\\packer\\extend.ps1'",
      "Set-Content -Path $p -Value '$ErrorActionPreference = ''Continue''' -Encoding ASCII",
      "Add-Content -Path $p -Value 'try {'",
      "Add-Content -Path $p -Value '  Get-Partition -DiskNumber 0 | Where-Object Type -eq ''Recovery'' | Remove-Partition -Confirm:$false -ErrorAction SilentlyContinue'",
      "Add-Content -Path $p -Value '  Update-Disk -Number 0'",
      "Add-Content -Path $p -Value '  $max = (Get-PartitionSupportedSize -DiskNumber 0 -PartitionNumber 3).SizeMax'",
      "Add-Content -Path $p -Value '  $cur = (Get-Partition -DiskNumber 0 -PartitionNumber 3).Size'",
      "Add-Content -Path $p -Value '  if ($max -gt $cur) { Resize-Partition -DiskNumber 0 -PartitionNumber 3 -Size $max }'",
      "Add-Content -Path $p -Value '} catch { $_ | Out-File C:\\ProgramData\\packer\\extend.err -Append }'",
      "reg add 'HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\RunOnce' /v 'ExtendC' /d 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\ProgramData\\packer\\extend.ps1' /f"
    ]
  }

  # Enable RDP for fallback access
  provisioner "powershell" {
    inline = [
      "Set-ItemProperty -Path 'HKLM:\\System\\CurrentControlSet\\Control\\Terminal Server' -Name 'fDenyTSConnections' -Value 0",
      "Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'"
    ]
  }

  # Ensure QEMU guest agent is installed and set to start automatically.
  # autounattend also installs it, but after sysprep it can be disabled —
  # re-assert here.
  provisioner "powershell" {
    inline = [
      "if (Test-Path 'D:\\guest-agent\\qemu-ga-x86_64.msi') {",
      "  Start-Process -FilePath msiexec.exe -ArgumentList '/i','D:\\guest-agent\\qemu-ga-x86_64.msi','/qn','/norestart' -Wait",
      "} elseif (Test-Path 'E:\\guest-agent\\qemu-ga-x86_64.msi') {",
      "  Start-Process -FilePath msiexec.exe -ArgumentList '/i','E:\\guest-agent\\qemu-ga-x86_64.msi','/qn','/norestart' -Wait",
      "}",
      "Get-Service QEMU-GA -ErrorAction SilentlyContinue | Set-Service -StartupType Automatic"
    ]
  }

  # Clean up
  provisioner "powershell" {
    inline = [
      "Remove-Item -Path C:\\Windows\\Temp\\* -Recurse -Force -ErrorAction SilentlyContinue",
      "Clear-RecycleBin -Force -ErrorAction SilentlyContinue",
      "Optimize-Volume -DriveLetter C -Defrag -ErrorAction SilentlyContinue"
    ]
  }

  # Sysprep with Cloudbase-Init's unattend (skips OOBE on cloned VMs)
  provisioner "powershell" {
    inline = [
      "& C:\\Windows\\System32\\Sysprep\\Sysprep.exe /oobe /generalize /shutdown /quiet /unattend:'C:\\Program Files\\Cloudbase Solutions\\Cloudbase-Init\\conf\\Unattend.xml'"
    ]
  }
}
