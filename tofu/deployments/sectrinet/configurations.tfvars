hosts = {
  "jupiter" = {
    #TODO Only necessary to specify IP until DNS is in place
    ansible_host   = "2.66.117.206"
    ansible_user   = "root"
    proxmox_node   = "pve"  # Actual Proxmox node name (differs from host key)
    storage_pool   = "local-zfs"

    # lxcs = {
    #   colab = {
    #     memory    = 4096
    #     disk_size = "32G"
    #
    #     mounts = [
    #       {name = "config", dataset = "tank/sectrinet", path = "/appdata"},
    #     ]
    #
    #     roles = [
    #       { name = "docker" }
    #     ]
    #     docker_services = [
    #       { name = "nextcloud" }
    #     ]
    #   }
    #
    #   tasks = {
    #     mounts = [
    #       {name = "config", dataset = "tank/sectrinet", path = "/appdata"}
    #     ]
    #     roles = [
    #       { name = "docker" }
    #     ]
    #     docker_services = [
    #       { name = "vikunja" }
    #     ]
    #   }
    # }

    vms = {
      loki = { # Ubuntu
        cores     = 12
        memory    = 32768
        disk_size = "720G"
        clone     = "ubuntu-2510-base"
        # TBA gitlab runner etc.
      }
      tvashtar = { # Windows — bios/disk_slot/network_model auto-derived from "windows-*" clone
        cores       = 12
        memory      = 32768
        disk_size   = "1024G"
        clone       = "windows-11-base"
        mac_address = "BC:24:11:5F:1A:EC" # Pinned identity
        pci_devices = [
          { mapping_id = "nvidia-gpu" },
          { mapping_id = "mobo-usb" },
          { mapping_id = "cpu-usb" },
          { mapping_id = "cpu-sound" },
        ]
      }
    }
  },
}
