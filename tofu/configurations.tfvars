hosts = {
  "proxmox" = {
    #TODO Only necessary to specify IP until DNS is in place
    ansible_host = "192.168.1.100"
    ansible_user = "default-user"

    lxcs = {
      media = {
        memory    = 4096
        disk_size = "32G"

        mounts = {
          configs = {
            zfs_dataset = "Tank2/appdata"
            ct_mountpoint = "/appdata"
          }
          movies = {
            zfs_dataset = "Tank3/movies"
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

        services = [ 
          { name = "docker" }
        ]
        docker_services = [
          { name = "gluetun" },
          { name = "serverarr" },
          { name = "jellyfin" }
        ]
      }
      backup = {
        services = [
          { name = "borgmatic" }
        ]
      }
      collaboration = {
        memory    = 4096
        disk_size = "32G"

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

        services = [ 
          { name = "docker" }
        ]
        docker_services = [
          { name = "nextcloud" }
        ]
      }
      authentication = {
        memory = 4096

        mounts = {
          configs = {
            zfs_dataset = "Tank2/appdata"
            ct_mountpoint = "/appdata"
          }
        }

        services = [ 
          { name = "docker" }
        ]
        docker_services = [
          { name = "authentik" }
        ]
      }

      network = {
        roles = [
          { name = "network/netbird" },
        ]
      }

      dls-server = {
        services = [
          { name = "dls-server" }
        ]
      }

      sharing = {
        roles = [
          { name = "network/samba" }
        ]
      }
    }
  },

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
