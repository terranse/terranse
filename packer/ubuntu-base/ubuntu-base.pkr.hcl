# Packer template for Ubuntu Base VM
#
# Creates a minimal Ubuntu cloud-init enabled template:
# - Cloud-init configured for Proxmox NoCloud datasource
# - QEMU guest agent
# - UEFI boot (q35/OVMF)
# - Ubuntu autoinstall (Subiquity) for automated setup
# - Optional SSH key bake-in for quick tests

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
  default     = "ubuntu"
  description = "OS family"
}

variable "os_version" {
  type        = string
  default     = "2510"
  description = "OS version"
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

variable "ssh_public_key" {
  type        = string
  default     = ""
  description = "SSH public key to bake into the template (optional)"
}

variable "ssh_username" {
  type        = string
  default     = "packer"
  description = "SSH username for provisioning"
}

variable "ssh_password" {
  type        = string
  sensitive   = true
  description = "SSH password for provisioning (from 1Password)"
}

variable "password_hash" {
  type        = string
  sensitive   = true
  description = "SHA-512 crypt hash of ssh_password, injected into autoinstall user-data"
}

# Resolve ISO from catalog
locals {
  os_key    = "${var.os_family}-${var.os_version}"
  os        = var.os_catalog[local.os_key]
  use_url   = local.os.iso_url != ""
  vm_name   = var.vm_name != "" ? var.vm_name : "${var.os_family}-${var.os_version}-base"
  user_data = templatefile("${path.root}/../http/autoinstall/user-data.tpl", {
    password_hash = var.password_hash
  })
}

source "proxmox-iso" "ubuntu-base" {
  # Proxmox connection
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_username
  token                    = var.proxmox_token
  node                     = var.proxmox_node
  insecure_skip_tls_verify = true

  # VM settings — no vm_id, Proxmox auto-assigns
  vm_name              = local.vm_name
  template_description = "Ubuntu ${var.os_version} Base Template - Built by Packer"

  # Hardware
  cores    = 2
  memory   = 2048
  cpu_type = "host"
  os       = local.os.os_type
  bios     = "ovmf"
  machine  = "q35"
  boot     = "order=scsi0;ide2"

  # EFI disk for UEFI boot
  efi_config {
    efi_storage_pool  = var.storage_pool
    efi_type          = "4m"
    pre_enrolled_keys = false
  }

  # Primary disk
  disks {
    type         = "scsi"
    disk_size    = "16G"
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

  # Boot command — enter GRUB CLI and boot with autoinstall
  boot_command = [
    "<wait3s>c<wait3s>",
    "linux /casper/vmlinuz --- autoinstall ds=\"nocloud-net;seedfrom=http://{{.HTTPIP}}:{{.HTTPPort}}/autoinstall/\"",
    "<enter><wait>",
    "initrd /casper/initrd",
    "<enter><wait>",
    "boot",
    "<enter>"
  ]
  boot_wait = "10s"

  # HTTP server for autoinstall — inline content so that user-data is
  # rendered from the template with the hash from 1Password
  http_content = {
    "/autoinstall/user-data" = local.user_data
    "/autoinstall/meta-data" = ""
  }
  http_port_min = 8100
  http_port_max = 8200

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

build {
  sources = ["source.proxmox-iso.ubuntu-base"]

  # Wait for cloud-init to complete
  provisioner "shell" {
    inline = [
      "while [ ! -f /var/lib/cloud/instance/boot-finished ]; do echo 'Waiting for cloud-init...'; sleep 5; done || true"
    ]
  }

  # Update system
  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get dist-upgrade -y"
    ]
  }

  # Setup cloud-init for Proxmox
  provisioner "shell" {
    script = "../scripts/setup-cloud-init.sh"
  }

  # Bake in SSH public key (optional, for quick tests without cloud-init)
  provisioner "shell" {
    inline = var.ssh_public_key != "" ? [
      "sudo mkdir -p /root/.ssh",
      "echo '${var.ssh_public_key}' | sudo tee -a /root/.ssh/authorized_keys",
      "sudo chmod 700 /root/.ssh && sudo chmod 600 /root/.ssh/authorized_keys",
    ] : ["echo 'No SSH key to bake in'"]
  }

  # Ensure qemu-guest-agent is enabled so Proxmox can talk to cloned VMs
  provisioner "shell" {
    inline = [
      "sudo systemctl enable qemu-guest-agent.service",
    ]
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
      "sudo rm -f /etc/cloud/cloud.cfg.d/subiquity-disable-cloudinit-networking.cfg",
      "sudo rm -f /etc/netplan/00-installer-config.yaml",
      "sudo sync"
    ]
  }
}
