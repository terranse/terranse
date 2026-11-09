# What goes where: a service used by Sectrinet is declared here, even when it
# physically runs on the home NAS. edholm/configurations.tfvars is for the home.
# (gitlab-runner predates this split and still lives in edholm.)
#
# This deployment only creates guests. It never writes DNS records, DHCP
# reservations or Caddy routes: those belong to edholm. Guests on the NAS use a
# dynamic address and register themselves as <name>.edholm.cc, so a name here
# must not be used in edholm. A plan fails if it is.
hosts = {
  proxmox = {
    ansible_host = "proxmox"
    ansible_user = "root"
    storage_pool = "FastStorage"
    lan_domain   = "edholm.cc"     # The name the LAN's DNS gives its guests
    gateway      = "192.168.1.1"

    lxcs = {
      salt = {
        memory    = 4096
        disk_size = "16G"

        mounts = [
          # Only its own folder: the rest of tank/appdata is home data.
          { name = "config", dataset = "tank/appdata", subdir = "salt", path = "/appdata/salt" },
        ]

        roles = [
          { name = "docker" }
        ]
        docker_services = [
          { name = "salt" }
        ]
      }
    }
  },

  # jupiter was replaced; its old VMs no longer exist and were dropped from state.
  # "jupiter" = {
  #   #TODO Only necessary to specify IP until DNS is in place
  #   ansible_host   = "2.66.117.206"
  #   ansible_user   = "root"
  #   proxmox_node   = "pve"  # Actual Proxmox node name (differs from host key)
  #   storage_pool   = "local-zfs"
  #
  #   # lxcs = {
  #   #   colab = {
  #   #     memory    = 4096
  #   #     disk_size = "32G"
  #   #
  #   #     mounts = [
  #   #       {name = "config", dataset = "tank/sectrinet", path = "/appdata"},
  #   #     ]
  #   #
  #   #     roles = [
  #   #       { name = "docker" }
  #   #     ]
  #   #     docker_services = [
  #   #       { name = "nextcloud" }
  #   #     ]
  #   #   }
  #   #
  #   #   tasks = {
  #   #     mounts = [
  #   #       {name = "config", dataset = "tank/sectrinet", path = "/appdata"}
  #   #     ]
  #   #     roles = [
  #   #       { name = "docker" }
  #   #     ]
  #   #     docker_services = [
  #   #       { name = "vikunja" }
  #   #     ]
  #   #   }
  #   # }
  #
  #   vms = {
  #     loki = { # Ubuntu
  #       cores     = 12
  #       memory    = 32768
  #       disk_size = "720G"
  #       clone     = "ubuntu-2510-base"
  #       # TBA gitlab runner etc.
  #     }
  #     tvashtar = { # Windows — bios/disk_slot/network_model auto-derived from "windows-*" clone
  #       cores       = 12
  #       memory      = 32768
  #       disk_size   = "1024G"
  #       clone       = "windows-11-base"
  #       mac_address = "BC:24:11:5F:1A:EC" # Pinned identity
  #       pci_devices = [
  #         { mapping_id = "nvidia-gpu" },
  #         { mapping_id = "mobo-usb" },
  #         { mapping_id = "cpu-usb" },
  #         { mapping_id = "cpu-sound" },
  #       ]
  #     }
  #   }
  # },
}
