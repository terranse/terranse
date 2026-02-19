# Variables for the gaming VM module

variable "host" {
  type        = string
  description = "Name of the Proxmox host"
}

variable "domain" {
  type        = string
  description = "Domain for DNS naming"
}

variable "ssh_key" {
  type        = string
  description = "SSH public key for VM access"
}

variable "configuration" {
  type = map(object({
    memory       = optional(number, 16384)
    cores        = optional(number, 8)
    disk_size    = optional(string, "64G")
    clone        = optional(string)
    storage_pool = optional(string, "FastStorage")

    # GPU configuration
    gpu_type       = optional(string, "none") # nvidia_vgpu, intel_sriov, none
    vgpu_profile   = optional(string)         # e.g., "Q-8C" for NVIDIA
    sriov_vf_index = optional(number)         # 0-6 for Intel SR-IOV
    nvidia_pci     = optional(string, "0000:41:00.0") # NVIDIA GPU PCI address

    # Physical display (Intel SR-IOV only)
    physical_display = optional(bool, false)

    # Gaming configuration
    sunshine_enabled   = optional(bool, true)
    steam_enabled      = optional(bool, true)
    retroarch_enabled  = optional(bool, false)
    game_storage_mount = optional(bool, true)
    snapshot_on_boot   = optional(bool, true)

    # Ansible roles
    roles = optional(list(object({
      name = string
      vars = optional(map(string), {})
    })), [])
  }))
  description = "Map of gaming VM configurations"
}

# NVIDIA vGPU mdev type mappings for RTX A5000
# These may need adjustment based on actual GPU model
variable "vgpu_mdev_types" {
  type = map(string)
  default = {
    "Q-1C"  = "nvidia-256"
    "Q-2C"  = "nvidia-257"
    "Q-4C"  = "nvidia-258"
    "Q-8C"  = "nvidia-259"
    "Q-12C" = "nvidia-260"
    "Q-24C" = "nvidia-261"
  }
  description = "Mapping of vGPU profile names to NVIDIA mdev type IDs"
}

variable "ansible_root" {
  type        = string
  description = "Path to the Ansible directory"
}
