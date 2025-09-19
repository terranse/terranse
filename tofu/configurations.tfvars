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
            "Tank2/appdata": "/appdata"
          }
          movies = {
            "Tank3/movies": "/storage/movies"
          }
          tv_series = {
            "Tank/windows_smb_series": "/storage/tv_series"
          }
          media = {
            "Tank/windows_smb_util": "/storage/media"
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
      colab = {
        memory    = 4096
        disk_size = "32G"

        mounts = {
          configs = {
            "Tank2/appdata" : "/appdata"
          }
          cloud = {
            "Tank3/cloud": "/storage/cloud"
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
            "Tank2/appdata": "/appdata"
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
