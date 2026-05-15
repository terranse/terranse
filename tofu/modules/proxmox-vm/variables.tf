variable "ssh_key" {
  type = string
}

variable "host" {
  type = string
}

variable "proxmox_node" {
  description = "Proxmox node name (defaults to host key if not set)"
  type        = string
  default     = ""
}

variable "storage_pool" {
  description = "Proxmox storage pool for VM disks"
  type        = string
  default     = "FastStorage"
}

variable "network_bridge" {
  description = "Proxmox network bridge"
  type        = string
  default     = "vmbr0"
}

variable "domain" {
  type = string
}

variable "configuration" {
  description = <<-EOT
    Map of VM configurations. Most hardware knobs (bios, disk_slot,
    network_model, os_type) are auto-derived from the clone template name:

      - "windows-*" clones → seabios + sata0 + e1000 + win11
      - everything else    → ovmf    + scsi0 + virtio + cloud-init

    Explicit values override the derived defaults.
  EOT
  type = map(object({
    cores         = optional(number, 2)
    memory        = optional(number, 2048)
    disk_size     = optional(string, "32G")
    disk_slot     = optional(string) # scsi0 / sata0 / virtio0 — derived from clone when null
    vmid          = optional(number)
    clone         = optional(string, "ubuntu-2604-base")
    full_clone    = optional(bool, false) # false = fast ZFS linked clone; true = full copy
    bios          = optional(string)      # "ovmf" or "seabios" — derived from clone when null
    os_type       = optional(string)      # proxmox os_type — derived from clone when null
    network_model = optional(string)      # virtio / e1000 / rtl8139 — derived from clone when null
    mac_address   = optional(string)      # Fixed MAC on net0; auto-generated when null
    pci_devices = optional(list(object({
      mapping_id    = optional(string)       # Proxmox resource mapping
      raw_id        = optional(string)       # Direct PCI address (e.g. "0000:41:00.0")
      mdev          = optional(string)       # Explicit mdev type (overrides vgpu_slice_gb)
      vgpu_slice_gb = optional(number)       # vGPU VRAM in GB — resolved to mdev type via vgpu_profiles
      pcie          = optional(bool, true)
      primary_gpu   = optional(bool, false)
      rombar        = optional(bool, true)
    })), [])
    roles = optional(list(object({ name = string, vars = optional(map(string), {}) })), [])
  }))
}

variable "vgpu_profiles" {
  description = "Map of vGPU VRAM sizes (GB) to NVIDIA mdev type IDs"
  type        = map(string)
  default = {
    "1"  = "nvidia-256"
    "2"  = "nvidia-257"
    "4"  = "nvidia-258"
    "8"  = "nvidia-259"
    "12" = "nvidia-260"
    "24" = "nvidia-261"
  }
}
