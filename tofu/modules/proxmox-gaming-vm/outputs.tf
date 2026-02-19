# Outputs for the gaming VM module

output "vm_details" {
  value = {
    for name, vm in proxmox_vm_qemu.gaming_vms : name => {
      vmid             = vm.vmid
      name             = vm.name
      memory           = vm.memory
      cores            = vm.cores
      gpu_type         = var.configuration[name].gpu_type
      vgpu_profile     = var.configuration[name].vgpu_profile
      sriov_vf_index   = var.configuration[name].sriov_vf_index
      physical_display = var.configuration[name].physical_display
      storage_pool     = var.configuration[name].storage_pool
    }
  }
  description = "Detailed information about created gaming VMs"
}

output "ansible_hosts" {
  value       = [for name, host in ansible_host.gaming_vm_hosts : host.name]
  description = "List of Ansible host entries created"
}

output "gpu_allocations" {
  value = {
    nvidia_vgpu = {
      for name, config in var.configuration : name => {
        profile  = config.vgpu_profile
        mdev     = lookup(var.vgpu_mdev_types, config.vgpu_profile, null)
        pci_addr = config.nvidia_pci
      } if config.gpu_type == "nvidia_vgpu"
    }
    intel_sriov = {
      for name, config in var.configuration : name => {
        vf_index         = config.sriov_vf_index
        pci_addr         = "0000:00:02.${config.sriov_vf_index + 1}"
        physical_display = config.physical_display
      } if config.gpu_type == "intel_sriov"
    }
  }
  description = "GPU allocation summary for all gaming VMs"
}
