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

      # DLS decommissioned: vGPU licensing now uses nvlts (local trusted store)
      # in the gaming guest — no network license server is needed. The LXC is
      # retained but runs nothing; delete this whole block to have tofu reclaim it.
      dls-server = {
        roles = [
          { name = "docker" }
        ]
        docker_services = []
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
        cores     = 12
        memory    = 32768
        disk_size = "64G"
        clone     = "ubuntu-2604-base"
        # DHCP on purpose. The guest registers its hostname in DNS when it takes
        # a lease, which is what makes gaming.edholm.cc resolve to it on the LAN.
        # A static address means no lease and no registration, so the name falls
        # through to the wildcard *.edholm.cc record pointing at the WAN IP — the
        # static IP CAUSED the split-horizon symptom it looked like a fix for.
        # (`ipconfig`/`nameserver` remain available for VMs that genuinely need
        # a fixed address.)

        # Same declaration style as the LXC mounts. A VM cannot bind-mount the
        # host, so each of these is published as a Proxmox directory mapping and
        # shared over virtiofs (the mapping id doubles as the virtiofs tag).
        mounts = [
          { name = "gaming-pc-games", dataset = "nvmepool/gaming/pc-games", path = "/mnt/games/pc" },
          { name = "gaming-emulation", dataset = "store/gaming/emulation", path = "/mnt/games/emulation" },
        ]
        pci_devices = [{
          mapping_id = "RTX-A5000"
          # Full 24 GB slice (RTXA5000-24Q). The A5000 only permits homogeneous
          # slices, so this VM must be the sole slice-holder: the driver won't
          # even offer 24Q as creatable while another vGPU is assigned.
          vgpu_slice_gb = 24
          pcie          = true
          # primary_gpu (x-vga) MUST stay false for a headless streaming VM:
          # making the vGPU the primary display hangs boot once the gaming
          # session service is enabled. Sunshine/Sway use the vGPU as a render
          # node; an emulated VGA stays the console.
          primary_gpu = false
          rombar      = false
        }]
        # Game storage is shared in via virtiofs (attached by the gpu-manager
        # role). Proxmox auto-backs a virtiofs VM with a shareable memfd, which
        # is incompatible with hugepages/ballooning — keep this VM on plain
        # memory (no balloon/hugepages) so the virtiofs attach takes effect.
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
