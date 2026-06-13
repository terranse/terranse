hosts = {
  "proxmox" = {
    ansible_host = "proxmox"
    ansible_user = "root"
    storage_pool = "FastStorage"

    lxcs = {
      media = {
        memory    = 4096
        disk_size = "32G"

        mounts = [
          {name = "config", dataset = "tank/appdata", path = "/appdata"},
          {name = "movies", dataset = "Tank3/movies", path = "/storage/movies"},
          {name = "tv_series", dataset = "Tank/windows_smb_series", path = "/storage/tv_series"},
          {name = "util", dataset = "Tank/windows_smb_util", path = "/storage/media"},
        ]

        roles = [
          { name = "docker" }
        ]
        docker_services = [
          { name = "gluetun" },
          { name = "serverarr" },
          { name = "jellyfin" }
        ]
      }
      backup = {
        mounts = [
          {dataset = "tank/appdata", path = "/appdata"},
          {dataset = "tank/cloud", path = "/storage/cloud"},
        ]
        roles = [
          { name = "borgmatic" }
        ]
      }
      colab = {
        memory    = 4096
        disk_size = "32G"

        mounts = [
          {name = "config", dataset = "tank/appdata", path = "/appdata"},
          {name = "cloud", dataset = "tank/cloud", path = "/storage/cloud"},
        ]

        roles = [ 
          { name = "docker" }
        ]
        docker_services = [
          { name = "nextcloud" }
        ]
      }
      authentication = {
        memory = 4096

        mounts = [
          {name = "config", dataset = "tank/appdata", path = "/appdata"},
        ]

        roles = [ 
          { name = "docker" }
        ]
        docker_services = [
          { name = "authentik" }
        ]
      }

      # TODO: Add configuration for a VPN client container, to route specific traffic through a VPN
      # TODO: Set, e.g., netbird to be a `service` instead of a role path
      network = {
        roles = [
          { name = "network" },
        ]
      }

      dls-server = {
        roles = [
          { name = "docker" }
        ]
        docker_services = [
          { name = "fastapi-dls" }
        ]
      }

      sharing = {
        mounts = [
          {name = "cloudShare", dataset = "tank/cloud", path = "/storage/cloud"}
        ]
        roles = [
          { name = "network/sharing" }
        ]
      }

      tasks = {
        mounts = [
          {name = "config", dataset = "tank/appdata", path = "/appdata"}
        ]
        roles = [
          { name = "docker" }
        ]
        docker_services = [
          { name = "vikunja" }
        ]
      }
    }
  },

  workstation = {
    ansible_host = "192.168.1.200"
    ansible_user = "root"
    storage_pool = "NVMePool"

    host_roles = [
      {
        name = "drivers"
        vars = {
          gpu_type          = "nvidia_vgpu"
          dls_server_ip     = "dls-server.edholm.cc"
          game_storage_host = "true"
          # ZFS pool names are case-sensitive and differ from the Proxmox
          # storage IDs: nvmepool = 2x Samsung 990 Pro NVMe (fast, PC games),
          # store = 2x Kingston SATA SSD mirror (emulation).
          game_storage_pools = [
            { pool = "nvmepool", name = "pc-games" },
            { pool = "store", name = "emulation" },
          ]
        }
      },
      { name = "gpu-manager" }
    ]

    lxcs = {
      gitlab-runner = {
        memory    = 32768
        cores     = 12
        disk_size = "128G"

        roles = [
          { name = "docker" }
        ]
        docker_services = [
          { name = "gitlab-runner" }
        ]
      }

      vagrant-runner = {
        memory    = 16384
        cores     = 8
        disk_size = "64G"

        roles = [
          { name = "vagrant-runner" }
        ]
      }
    }

    vms = {
      gaming = {
        cores     = 8
        memory    = 16384
        disk_size = "64G"
        clone     = "ubuntu-2604-base"
        pci_devices = [{
          mapping_id    = "RTX-A5000"
          vgpu_slice_gb = 8
          pcie          = true
          # primary_gpu (x-vga) MUST stay false for a headless streaming VM:
          # making the vGPU the primary display hangs boot once the gamescope
          # session service is enabled. Sunshine/gamescope use the vGPU as a
          # render node; an emulated VGA stays the console.
          primary_gpu = false
          rombar      = false
        }]
        roles = [{
          name = "gaming"
          vars = {
            gpu_type           = "nvidia_vgpu"
            dls_server_ip      = "dls-server.edholm.cc"
            sunshine_enabled   = "true"
            steam_enabled      = "true"
            retroarch_enabled  = "true"
            lutris_enabled     = "true"
            game_storage_mount = "true"
            snapshot_on_boot   = "true"
          }
        }]
      }
    }
  }
}
