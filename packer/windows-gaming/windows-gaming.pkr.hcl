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

variable "vm_id" {
  type        = number
  default     = 9001
  description = "VM ID for the template"
}

variable "vm_name" {
  type        = string
  default     = "windows-11-gaming"
  description = "Name of the VM template"
}

variable "iso_file" {
  type        = string
  default     = "local:iso/Win11_23H2_English_x64.iso"
  description = "Path to Windows ISO"
}

variable "virtio_iso" {
  type        = string
  default     = "local:iso/virtio-win.iso"
  description = "Path to VirtIO drivers ISO"
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
  vm_name              = var.vm_name
  template_description = "Windows 11 Gaming VM Template - Built by Packer"

  # Hardware
  cores    = 4
  memory   = 8192
  cpu_type = "host"
  os       = "win11"
  bios     = "ovmf"
  machine  = "q35"

  # TPM for Windows 11
  tpm_state {
    tpm_storage_pool = "local-lvm"
    version          = "v2.0"
  }

  # EFI disk for UEFI boot
  efi_config {
    efi_storage_pool  = "local-lvm"
    efi_type          = "4m"
    pre_enrolled_keys = true
  }

  # Primary disk (VirtIO for performance)
  disks {
    type              = "scsi"
    disk_size         = "100G"
    storage_pool      = "local-lvm"
    storage_pool_type = "lvm"
    format            = "raw"
  }

  # Network (VirtIO)
  network_adapters {
    model  = "virtio"
    bridge = "vmbr0"
  }

  # ISO files
  iso_file = var.iso_file
  additional_iso_files {
    device           = "sata1"
    iso_file         = var.virtio_iso
    iso_storage_pool = "local"
    unmount          = true
  }

  # Floppy with autounattend.xml
  additional_iso_files {
    device   = "sata2"
    cd_files = ["./autounattend.xml", "./scripts/*"]
    cd_label = "OEMDRV"
  }

  unmount_iso = true

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
  cloud_init_storage_pool = "local-lvm"

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
      "& C:\\Windows\\System32\\Sysprep\\Sysprep.exe /oobe /generalize /shutdown /quiet"
    ]
  }
}
