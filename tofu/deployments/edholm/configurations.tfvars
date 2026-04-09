hosts = {
  "proxmox" = {
    #TODO Only necessary to specify IP until DNS is in place
    # ansible_host = "192.168.1.100"
    ansible_user = "root"

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
          { name = "dls-server" }
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
    # TODO: Uncomment once DNS is configured, or set ansible_host to the workstation IP
    # ansible_host = "192.168.1.200"
    ansible_user = "root"

    lxcs = {
      # GitLab runner isolated in its own LXC — never touches existing workstation setup.
      # TODO: Verify that the Proxmox storage pool "FastStorage" exists on the workstation node,
      #       or update tofu/modules/proxmox-container/main.tf to accept a configurable pool.
      gitlab-runner = {
        memory    = 2048
        disk_size = "16G"

        roles = [
          { name = "docker" }
        ]
        docker_services = [
          { name = "gitlab-runner" }
        ]
      }
    }
  }
}
