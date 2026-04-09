# Packer template for Windows Gaming VM
#
# Creates a Windows 11 template optimized for gaming:
# - VirtIO drivers for performance
# - NVIDIA vGPU guest drivers (manual step - see README)
# - Sunshine streaming server
# - Steam pre-installed
#
# Prerequisites:
#   - Windows 11 ISO uploaded to Proxmox
#   - VirtIO drivers ISO (virtio-win.iso)
#   - Cloudbase-Init for cloud-init support

packer {
  required_plugins {
    proxmox = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

# Variables
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

variable "vm_id" {
  type        = number
  default     = 9001
  description = "VM ID for the template"
}

variable "storage_pool" {
  type        = string
  default     = "local-lvm"
  description = "Proxmox storage pool for VM disks and EFI"
}

variable "vm_name" {
  type        = string
  default     = ""
  description = "Override VM template name (defaults to {os_family}-{os_version}-gaming)"
}

variable "winrm_username" {
  type        = string
  default     = "packer"
  description = "WinRM username for provisioning"
}

variable "winrm_password" {
  type        = string
  default     = "P@cker2024!"
  sensitive   = true
  description = "WinRM password for provisioning"
}

# Resolve ISO from catalog
locals {
  os_key         = "${var.os_family}-${var.os_version}"
  os             = var.os_catalog[local.os_key]
  use_virtio_url = var.virtio_iso_url != ""
  vm_name        = var.vm_name != "" ? var.vm_name : "${var.os_family}-${var.os_version}-gaming"
}

# Source configuration
source "proxmox-iso" "windows-gaming" {
  # Proxmox connection
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_username
  token                    = var.proxmox_token
  node                     = var.proxmox_node
  insecure_skip_tls_verify = true

  # VM settings
  vm_id                = var.vm_id
  vm_name              = local.vm_name
  template_description = "Windows ${var.os_version} Gaming VM Template - Built by Packer"

  # Hardware
  cores    = 4
  memory   = 16384
  cpu_type = "host"
  os       = local.os.os_type
  bios     = "ovmf"
  machine  = "q35"
  boot     = "order=ide2;scsi0"

  # EFI disk for UEFI boot (TPM bypassed via autounattend LabConfig registry keys)
  efi_config {
    efi_storage_pool  = var.storage_pool
    efi_type          = "4m"
    pre_enrolled_keys = true
  }

  # Primary disk (VirtIO for performance)
  disks {
    type         = "scsi"
    disk_size    = "100G"
    storage_pool = var.storage_pool
    format       = "raw"
  }

  # Network (VirtIO)
  network_adapters {
    model  = "virtio"
    bridge = "vmbr0"
  }

  # Windows ISO — resolved from catalog (pre-uploaded, uses iso_file)
  boot_iso {
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

  # Floppy with autounattend.xml
  additional_iso_files {
    type             = "sata"
    index            = 2
    cd_files         = ["./autounattend.xml", "./scripts/*"]
    cd_label         = "OEMDRV"
    iso_storage_pool = "local"
  }

  # Boot settings
  boot_command = ["<spacebar>"]
  boot_wait    = "5s"

  # WinRM connection (configured by autounattend.xml)
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

# Build configuration
build {
  sources = ["source.proxmox-iso.windows-gaming"]

  # Wait for Windows to finish setup
  provisioner "windows-shell" {
    inline = [
      "echo Waiting for Windows to settle...",
      "timeout /t 30 /nobreak"
    ]
  }

  # Install Chocolatey package manager
  provisioner "powershell" {
    inline = [
      "Set-ExecutionPolicy Bypass -Scope Process -Force",
      "[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072",
      "iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))"
    ]
  }

  # Install gaming prerequisites
  provisioner "powershell" {
    inline = [
      "choco install -y 7zip",
      "choco install -y vcredist-all",
      "choco install -y directx",
      "choco install -y dotnet-runtime"
    ]
  }

  # Install Steam
  provisioner "powershell" {
    inline = [
      "choco install -y steam"
    ]
  }

  # Install Sunshine (game streaming)
  provisioner "powershell" {
    inline = [
      "$sunshineUrl = (Invoke-RestMethod -Uri 'https://api.github.com/repos/LizardByte/Sunshine/releases/latest').assets | Where-Object { $_.name -like '*installer*.exe' } | Select-Object -First 1 -ExpandProperty browser_download_url",
      "Invoke-WebRequest -Uri $sunshineUrl -OutFile C:\\Windows\\Temp\\sunshine-setup.exe",
      "Start-Process -FilePath C:\\Windows\\Temp\\sunshine-setup.exe -ArgumentList '/S' -Wait",
      "Remove-Item C:\\Windows\\Temp\\sunshine-setup.exe -Force"
    ]
  }

  # Configure Sunshine to start on login
  provisioner "powershell" {
    inline = [
      "$startupFolder = [Environment]::GetFolderPath('CommonStartup')",
      "$shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut(\"$startupFolder\\Sunshine.lnk\")",
      "$shortcut.TargetPath = 'C:\\Program Files\\Sunshine\\sunshine.exe'",
      "$shortcut.Save()"
    ]
  }

  # Install Cloudbase-Init for cloud-init support
  provisioner "powershell" {
    inline = [
      "$cloudbaseUrl = 'https://cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi'",
      "Invoke-WebRequest -Uri $cloudbaseUrl -OutFile C:\\Windows\\Temp\\CloudbaseInit.msi",
      "Start-Process -FilePath msiexec.exe -ArgumentList '/i', 'C:\\Windows\\Temp\\CloudbaseInit.msi', '/qn', '/norestart' -Wait",
      "Remove-Item C:\\Windows\\Temp\\CloudbaseInit.msi -Force"
    ]
  }

  # Copy first-boot driver installation script
  # This will be executed by Cloudbase-Init on first boot after cloning
  provisioner "powershell" {
    inline = [
      "New-Item -ItemType Directory -Path 'C:\\Program Files\\Cloudbase Solutions\\Cloudbase-Init\\LocalScripts' -Force",
      "@'",
      "# First-boot gaming setup script",
      "# This installs NVIDIA drivers from NFS and configures Sunshine",
      "",
      "$LogFile = \"C:\\Windows\\Temp\\gaming-firstboot.log\"",
      "\"Starting first-boot gaming setup...\" | Out-File $LogFile",
      "",
      "# Enable NFS client",
      "try {",
      "    Enable-WindowsOptionalFeature -Online -FeatureName ServicesForNFS-ClientOnly -NoRestart",
      "} catch { \"NFS already enabled or not available\" | Out-File $LogFile -Append }",
      "",
      "# The full setup will be done by Ansible after VM is cloned",
      "# This script just ensures NFS is available for driver mounting",
      "\"First-boot prep complete. Run Ansible gaming role for full setup.\" | Out-File $LogFile -Append",
      "'@ | Out-File -FilePath 'C:\\Program Files\\Cloudbase Solutions\\Cloudbase-Init\\LocalScripts\\gaming-setup.ps1' -Encoding UTF8"
    ]
  }

  # Enable RDP for fallback access
  provisioner "powershell" {
    inline = [
      "Set-ItemProperty -Path 'HKLM:\\System\\CurrentControlSet\\Control\\Terminal Server' -Name 'fDenyTSConnections' -Value 0",
      "Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'"
    ]
  }

  # Clean up and prepare for sysprep
  provisioner "powershell" {
    inline = [
      "Remove-Item -Path C:\\Windows\\Temp\\* -Recurse -Force -ErrorAction SilentlyContinue",
      "Clear-RecycleBin -Force -ErrorAction SilentlyContinue",
      "Optimize-Volume -DriveLetter C -Defrag -ErrorAction SilentlyContinue"
    ]
  }

  # Sysprep for generalization
  provisioner "powershell" {
    inline = [
      "& C:\\Windows\\System32\\Sysprep\\Sysprep.exe /oobe /generalize /shutdown /quiet /unattend:'C:\\Program Files\\Cloudbase Solutions\\Cloudbase-Init\\conf\\Unattend.xml'"
    ]
  }
}
