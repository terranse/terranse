# Packer template for Debian Gaming VM
#
# Creates a Debian 12 cloud-init enabled template optimized for gaming:
# - NVIDIA vGPU guest drivers (downloaded separately)
# - Intel graphics support
# - Xfce desktop environment
# - Steam dependencies pre-installed
# - Sunshine streaming server
# - Cloud-init for dynamic configuration

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
  default     = "debian"
  description = "OS family"
}

variable "os_version" {
  type        = string
  default     = "12"
  description = "OS version"
}

variable "virtio_iso_url" {
  type        = string
  default     = ""
  description = "Unused in Linux templates — declared so the shared catalog var-file does not error"
}

variable "virtio_iso_checksum" {
  type        = string
  default     = ""
  description = "Unused in Linux templates — declared so the shared catalog var-file does not error"
}

variable "vm_id" {
  type        = number
  default     = 9000
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

variable "ssh_username" {
  type        = string
  default     = "packer"
  description = "SSH username for provisioning"
}

variable "ssh_password" {
  type        = string
  default     = "packer"
  sensitive   = true
  description = "SSH password for provisioning"
}

# Resolve ISO from catalog
locals {
  os_key  = "${var.os_family}-${var.os_version}"
  os      = var.os_catalog[local.os_key]
  use_url = local.os.iso_url != ""
  vm_name = var.vm_name != "" ? var.vm_name : "${var.os_family}-${var.os_version}-gaming"
}

# Source configuration
source "proxmox-iso" "debian-gaming" {
  # Proxmox connection
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_username
  token                    = var.proxmox_token
  node                     = var.proxmox_node
  insecure_skip_tls_verify = true

  # VM settings
  vm_id                = var.vm_id
  vm_name              = local.vm_name
  template_description = "Debian ${var.os_version} Gaming VM Template - Built by Packer"

  # Hardware
  cores    = 4
  memory   = 8192
  cpu_type = "host"
  os       = local.os.os_type
  bios     = "ovmf"
  machine  = "q35"

  # EFI disk for UEFI boot
  efi_config {
    efi_storage_pool  = var.storage_pool
    efi_type          = "4m"
    pre_enrolled_keys = false
  }

  # Primary disk
  disks {
    type         = "scsi"
    disk_size    = "32G"
    storage_pool = var.storage_pool
    format       = "raw"
  }

  # Network
  network_adapters {
    model  = "virtio"
    bridge = "vmbr0"
  }

  # ISO — resolved from catalog (downloaded directly by Proxmox node)
  boot_iso {
    iso_url          = local.use_url ? local.os.iso_url : null
    iso_checksum     = local.use_url ? local.os.iso_checksum : null
    iso_file         = local.use_url ? null : local.os.iso_file
    iso_storage_pool = "local"

    unmount          = true
  }

  # Boot command — enter GRUB CLI (UEFI) and boot with preseed
  boot_command = [
    "c<wait5>",
    "linux /install.amd/vmlinuz auto=true priority=critical preseed/url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg hostname=debian-gaming domain=local interface=auto --- quiet",
    "<enter><wait5>",
    "initrd /install.amd/initrd.gz",
    "<enter><wait5>",
    "boot",
    "<enter>"
  ]
  boot_wait = "10s"

  # HTTP server for preseed
  http_directory = "../http"
  http_port_min  = 8100
  http_port_max  = 8200

  # SSH connection
  ssh_username           = var.ssh_username
  ssh_password           = var.ssh_password
  ssh_timeout            = "30m"
  ssh_handshake_attempts = 100

  # Cloud-init
  cloud_init              = true
  cloud_init_storage_pool = var.storage_pool

  # QEMU guest agent
  qemu_agent = true
}

# Build configuration
build {
  sources = ["source.proxmox-iso.debian-gaming"]

  # Wait for cloud-init to complete (if running)
  provisioner "shell" {
    inline = [
      "while [ ! -f /var/lib/cloud/instance/boot-finished ]; do echo 'Waiting for cloud-init...'; sleep 5; done || true"
    ]
  }

  # Update system
  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get upgrade -y",
      "sudo apt-get dist-upgrade -y"
    ]
  }

  # Install desktop environment and gaming prerequisites
  provisioner "shell" {
    script = "../scripts/install-gaming-base.sh"
  }

  # Install Steam dependencies
  provisioner "shell" {
    script = "../scripts/install-steam.sh"
  }

  # Install Sunshine
  provisioner "shell" {
    script = "../scripts/install-sunshine.sh"
  }

  # Install NVIDIA driver prerequisites (driver installed via Ansible)
  provisioner "shell" {
    script = "../scripts/install-nvidia-prereqs.sh"
  }

  # Clean up
  provisioner "shell" {
    inline = [
      "sudo apt-get autoremove -y",
      "sudo apt-get clean",
      "sudo rm -rf /tmp/*",
      "sudo rm -rf /var/tmp/*",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id",
      "sudo cloud-init clean --logs --seed",
      "sudo rm -f /etc/ssh/ssh_host_*",
      "sudo sync"
    ]
  }
}
