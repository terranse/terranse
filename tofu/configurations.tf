locals {
  hosts = {
    proxmox = {
      #TODO Only necessary to specify IP until DNS is in place
      ansible_host = "192.168.1.100"
      ansible_user = var.user

      lxcs = {
        media = {
          memory    = 4096
          disk_size = "32G"
          #vmid      = 101

          mounts = {
            configs = {
              zfs_dataset = "Tank2/appdata"
              ct_mountpoint = "/appdata"
            }
            movies = {
              zfs_dataset = "Tank/windows_smb"
              ct_mountpoint = "/storage/movies"
            }
            tv_series = {
              zfs_dataset = "Tank/windows_smb_series"
              ct_mountpoint = "/storage/tv_series"
            }
            media = {
              zfs_dataset = "Tank/windows_smb_util"
              ct_mountpoint = "/storage/media"
            }
          }

          services  = [ "docker" ]
          docker_services = [
            "docker/gluetun",
            "docker/serverarr",
            "docker/jellyfin"
          ]
        }
        backup = {
          #vmid = 102
          services = [ "borgmatic" ]
        }
        network = {
          #vmid = 103
        }
        collaboration = {
          memory    = 4096
          disk_size = "32G"
          #vmid      = 104

          mounts = {
            configs = {
              zfs_dataset = "Tank2/appdata"
              ct_mountpoint = "/appdata"
            }
            cloud = {
              zfs_dataset = "Tank3/cloud"
              ct_mountpoint = "/storage/cloud"
            }
          }

          services = [ "docker" ]
          docker_services = [
            "docker/nextcloud"
          ]
        }
        authentication = {
          memory = 4096
          #vmid   = 105

          mounts = {
            configs = {
              zfs_dataset = "Tank2/appdata"
              ct_mountpoint = "/appdata"
            }
          }

          services = [ "docker" ]
          docker_services = [
            "docker/authentik"
          ]
        }
        network = {
          #vmid = 107
          roles = [ "network/netbird" ]
        }
        dls-server = {
          #vmid = 108
          services = [ "dls-server "]
        }
        sharing = {
          #vmid = 109
          roles = [ "network/samba" ]
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
