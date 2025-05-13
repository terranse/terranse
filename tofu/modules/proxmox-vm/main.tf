terraform {
  required_providers {
    proxmox = {
      source = "telmate/proxmox"
      version = ">= 2.9.14"
      configuration_aliases = [ proxmox.vm ]
    }
  }
}

locals {
  module_ip = "192.168.1.${var.vmid}"
}
# Below is taken from a guide at https://austinsnerdythings.com/2021/09/01/how-to-deploy-vms-in-proxmox-with-terraform/

resource "proxmox_vm_qemu" "test_vm" {
  #count = var.count # just want 1 for now, set to 0 and apply to destroy VM
  # name = "test-vm-${count.index + 1}" #count.index starts at 0, so + 1 means this VM will be named test-vm-1 in proxmox
  # this now reaches out to the vars file. I could've also used this var above in the pm_api_url setting but wanted to spell it out up there.
  # target_node is different than api_url. target_node is which node hosts the template and thus also which node will host the new VM.
  # It can be different than the host you use to communicate with the API. the variable contains the contents "prox-1u"
  target_node = "proxmox"
  vmid        = var.vmid
  name        = var.hostname

  # another variable with contents "ubuntu-2004-cloudinit-template"
  # clone = var.template_name
  # basic VM settings here. agent refers to guest agent
  agent     = 1
  os_type   = "cloud-init"
  clone     = var.clone
  cores     = var.cores
  sockets   = 1
  cpu       = "host"
  memory    = var.memory
  scsihw    = "virtio-scsi-pci"
  bootdisk  = "scsi0"
  disk {
    slot     = 0
    # set disk size here. leave it small for testing because expanding the disk takes time.
    size     = var.disk_size
    type     = "scsi"
    storage  = "FastStorage"
    iothread = 1
  }
  
  # if you want two NICs, just copy this whole network section and duplicate it
  network {
    model  = "virtio"
    bridge = "vmbr0"
  }
  # not sure exactly what this is for. presumably something about MAC addresses and ignore network changes during the life of the VM
  lifecycle {
    ignore_changes = [
      network,
    ]
  }
  
  # the ${count.index + 1} thing appends text to the end of the ip address
  # in this case, since we are only adding a single VM, the IP will
  # be 10.98.1.91 since count.index starts at 0. this is how you can create
  # multiple VMs and have an IP assigned to each (.91, .92, .93, etc.)
  #ipconfig0 = "ip=10.98.1.9${count.index + 1}/24,gw=10.98.1.1"
  
  # sshkeys set using variables. the variable contains the text of the key.
  sshkeys = <<EOF
  ${var.ssh_key}
  EOF
}

// This is needed for a module to make values available to the calling root module
output "module_ip" {
  value = local.module_ip
}
