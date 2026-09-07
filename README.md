# Terranse 🚀

Deploy and configure your homelab or production infrastructure using OpenTofu
and Ansible - from bare metal to fully configured services.

## 🎯 What is Terranse?

Terranse combines infrastructure provisioning (OpenTofu) with configuration
management (Ansible) to automate your entire deployment pipeline. It handles
the complexity of coordinating these tools while maintaining stateful
infrastructure management.

## 📋 Features & Benefits

### Why Terranse?

- **🔧 Unified Deployment** - Infrastructure and configuration in one workflow
- **📦 Container-Ready** - Automatic Docker and Docker Compose setup on all hosts
- **🔄 Stateful Management** - OpenTofu handles infrastructure state reliably
- **🎨 Modular Design** - Add new capabilities through modules
- **🏠 Homelab Friendly** - Perfect for self-hosted services and experimentation

### Example Use Cases

```bash
# Deploy Proxmox VMs or LXCs with Docker services
tofu apply

# Configure hosts with Ansible
ansible-playbook playbook.yml
```

## 🛠️ Installation

### Prerequisites

- **OpenTofu** >= 1.6.0 (required - Terraform not supported)
- **Ansible** >= 2.15
- **1Password CLI** (for secrets management)

### Quick Install

```bash
# Clone the repository
git clone https://github.com/terranse/terranse.git
cd terranse

# Install Python dependencies
pip install -r requirements.txt

# Install Ansible requirements
ansible-galaxy install -r requirements.yml

# Initialize OpenTofu
tofu init
```

### Supported Platforms

- **Proxmox** - Full support for LXC provisioning -- VMs are a work in progress
- More platforms coming soon with new modules

### Limitations

This project is aimed at being extensible by anyone, but currently only support
a (very) limited set of platform setups. Right now the setup uses:

- Proxmox with ZFS datasets for storage
- Only Debian-based distributions (e.g., Debian, Ubuntu)
- Docker for nested containers, Podman not explored
- 1password for secrets management
- Manual firewall/network configuration (to be automated in the future)

All of these limitations are intended to be mitigated in the future, and you
are welcome to contribute to the project to help improve it!

## 🚀 Getting Started

Configuration is centralized in the `configurations.tf` file. Here's a
minimal example:

```hcl
# configurations.tf
locals {
  hosts = {
    proxmox = {
      # Needed if no local DNS is in place
      ansible_host = "192.168.1.100"
      ansible_user = var.user

      lxcs = {
        media = {
          memory    = 4096
          disk_size = "32G"

          mounts = {
            media = {
              zfs_dataset = "Tank/media"
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
          services = [ "borgmatic" ]
        }
        # Additional LXC configurations can be added here
      }
    # Add more hosts as needed
    }
  }
}
```

Note that, e.g., `memory` and `disk_size` are left out from the `backup` LXC,
and leaving those out will use the defaults from the module.

Deploy your infrastructure:

```bash
# Plan first to ensure no errors are found
tofu plan

# Apply plan
tofu apply

# Configure hosts with Ansible; this will be automatic in the future
ansible-playbook playbook.yml
```

## ❄️ NixOS machines

Most machines here are provisioned by Ansible. A few are not: their whole
configuration is declared in this repo's flake, and Ansible must never touch
them.

`configurations.tfvars` still says a machine *exists* and how to reach it.
`nix/machines.nix` says what it *does*:

```nix
{
  herdr = {
    system = "x86_64-linux";
    kind   = "lxc";              # nix/profiles/lxc.nix -- a Proxmox container
    roles  = [ { name = "dev"; } ];  # nix/roles/dev.nix
  };
}
```

`kind` is the only branch in the flake. `metal` brings in disko, systemd-boot
and EFI variable access; `lxc` brings in nixpkgs' `proxmox-lxc` profile, which
sets `boot.isContainer` and so needs neither a `disko.nix` nor a
`hardware.nix`. They are mutually exclusive: a bootloader and the container's
init-script loader both define `system.build.installBootLoader`, which has no
merge function.

Roles are plain NixOS modules under `nix/roles/`, indexed by name in
`nix/roles/default.nix`. Listing one in a machine's `roles` sets
`roles.<name>.enable = true`; a typo names the machine and lists the valid
roles rather than failing with a bare "attribute missing".

On the tofu side, such a container carries three extra attributes:
`ostemplate` (a template built here rather than pulled from the Proxmox
appliance repository), `ostype`, and `provision = "none"` — which is what
keeps every Ansible play, including the fleet-wide SSH hardening one, away
from it. It keeps its inventory entry, its deterministic MAC and its DHCP
reservation.

```bash
# Everything the flake claims
just check-nix

# Create a container: build its rootfs and put it on the Proxmox node,
# then let tofu create the CT from it. Only needed once.
just push-lxc-template herdr
just apply-tofu edholm

# Update it afterwards. Built ON the box -- it has more cores than the laptop.
just deploy-nixos herdr

# Install a host's secrets from 1Password. Values live only inside the pipe.
just secrets herdr
```

## 🤝 Contributing

Contributions are welcome! New modules need to integrate with the configuration
variables in `configurations.tf`.

## ❓ FAQ

**Q: Why OpenTofu instead of Terraform?**  
A: Terranse uses `for_each` in provider configurations, which is only
supported in OpenTofu.

**Q: Can I import existing infrastructure?**  
A: OpenTofu has some import capabilities, but this hasn't been explored with
Terranse yet.

**Q: How do I add support for new platforms?**  
A: Create a new module and integrate it with the configuration variables
in `configurations.tf`.

**Q: Is Windows support planned?**  
A: No, Terranse is designed for Linux hosts only.

**Q: Can I use multiple Proxmox nodes?**  
A: Yes! Define multiple nodes in the `hosts` variable and reference
them in your VM configurations.

---

<p align="center">
  Made with ❤️ by the Terranse community
</p>
