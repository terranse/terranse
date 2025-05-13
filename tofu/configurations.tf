locals {
  hosts = {
    proxmox = {
      TODO: Only necessary to specify IP until DNS is in place
      ansible_host = "192.168.1.100"
      ansible_user = "root"

      lxcs = {
        media = {
          memory    = 4096
          disk_size = "32G"
          vmid      = 101

          mounts = {
            config = "/storage/config"
          }

          services  = [ "docker" ]
          docker_services = [
            "docker/serverarr"
          ]
        }
        backup = {
          vmid = 102
        }
        network = {
          vmid = 103
        }
        collaboration = {
          memory    = 4096
          disk_size = "32G"
          vmid      = 104
        }
        authentication = {
          memory = 4096
          vmid   = 105
        }
        network = {
          vmid = 107
        }
        dls-server = {
          vmid = 108
        }
        sharing = {
          vmid = 109
        }
      }
    }

   # workstation = {
   #   ansible_host = "192.168.1.200"
   #   ansible_user = "root"

   #   vms = {
   #     windows_main = {
   #       memory = "48G"
   #       image = var.latest_windows
   #     }
   #   }
   # }
  }
}
