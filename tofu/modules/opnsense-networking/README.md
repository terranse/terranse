# OPNSense Networking Module

This OpenTofu/Terraform module manages OPNSense networking configuration and Caddy reverse proxy setup for Proxmox LXC containers and Docker services.

## Features

1. **DHCP Reservations**: Creates Kea DHCP reservations for Proxmox LXC containers
2. **DNS Domain Overrides**: Configures Unbound DNS domain overrides for local name resolution
3. **Caddy Reverse Proxy**: Sets up Caddy reverse proxy configurations for Docker services running in LXC containers

## Requirements

- OpenTofu/Terraform >= 1.3.0
- OPNSense with API enabled and Kea DHCP configured
- Caddy running on OPNSense with admin API enabled (default port 2019)
- Caddy listening on port 54443 (default) for reverse proxy traffic
- MAC addresses available from Proxmox LXC provider (may need to be added to proxmox-container module outputs)

## Providers

- [browningluke/opnsense](https://registry.terraform.io/providers/browningluke/opnsense/latest) >= 0.1.0
- [conradludgate/caddy](https://registry.terraform.io/providers/conradludgate/caddy/latest) >= 0.1.0

## Important Notes

- This module does NOT configure TLS/ACME automatically. TLS should be configured in OPNSense's Caddy installation separately.
- The module does NOT include health checks as they are not documented in the Caddy Terraform provider.
- Service names in `docker_services` MUST match the Ansible template file names (e.g., `jellyfin` → `jellyfin.yaml.j2`).

## Usage

### Basic Example

```hcl
# First, create a Kea subnet in OPNSense
resource "opnsense_kea_subnet" "lan" {
  subnet      = "192.168.1.0/24"
  description = "LAN subnet"
}

module "opnsense_networking" {
  source = "./modules/opnsense-networking"

  domain        = var.domain  # Should come from root defaults
  kea_subnet_id = opnsense_kea_subnet.lan.id

  # Configure DHCP and DNS for LXC containers
  lxc_containers = {
    "media" = {
      ip_address  = "192.168.1.100"
      mac_address = "BC:24:11:AA:BB:CC"
    }
    "colab" = {
      ip_address  = "192.168.1.101"
      mac_address = "BC:24:11:AA:BB:DD"
    }
  }

  # Configure reverse proxy for Docker services
  # Key = service name (becomes subdomain AND must match ansible template file name)
  # Value = container hosting the service and port
  docker_services = {
    "jellyfin" = {
      container_name = "media"  # LXC container name
      port           = 8096
    }
    "nextcloud" = {
      container_name = "colab"  # LXC container name
      port           = 80
    }
  }

  caddy_listen_port = 54443
}
```

### Integration Example (from main tofu configuration)

See the commented example in `/tofu/main.tf` for how to integrate this module with the existing proxmox-container module setup. Key points:

1. You'll need to create a `opnsense_kea_subnet` resource first
2. MAC addresses may need to be added as outputs from the proxmox-container module
3. Service names in `docker_services` must match both:
   - The Ansible template file name (e.g., `jellyfin.yaml.j2`)
   - The subdomain you want (e.g., `jellyfin.edholm.cc`)

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| domain | Base domain for DNS overrides and reverse proxy hostnames (should come from root defaults.tf) | `string` | n/a | yes |
| kea_subnet_id | Kea DHCP subnet ID from opnsense_kea_subnet resource | `string` | n/a | yes |
| lxc_containers | Map of LXC containers with IP and MAC addresses | `map(object)` | `{}` | no |
| docker_services | Map of Docker services for reverse proxy (key must match ansible template name) | `map(object)` | `{}` | no |
| caddy_listen_port | Port for Caddy reverse proxy to listen on | `number` | `54443` | no |

## Outputs

| Name | Description |
|------|-------------|
| dhcp_reservations | Map of DHCP reservations created (includes hostname, IP, MAC, and resource ID) |
| dns_overrides | Map of DNS domain overrides created (includes domain, server, enabled status, and resource ID) |
| reverse_proxy_endpoints | Map of reverse proxy endpoints configured with public URLs and upstreams |
| caddy_server_names | Names of Caddy server resources created |

## Implementation Notes

### Docker Service Template Mapping

**Critical**: The service name (key in `docker_services` map) MUST correspond to the Ansible template file name in `ansible/roles/docker/templates/`:

- Service key: `jellyfin` → Template: `jellyfin.yaml.j2`
- Service key: `nextcloud` → Template: `nextcloud.yaml.j2`

This ensures consistency between the reverse proxy configuration and the actual deployed services.

### Caddy Configuration

Caddy must be running on OPNSense with the admin API enabled:

1. Install Caddy on OPNSense
2. Configure Caddy admin endpoint (default: `http://localhost:2019`)
3. Caddy should listen on port 54443 (or your configured port) for reverse proxy traffic
4. TLS/ACME must be configured in OPNSense Caddy separately (not handled by this module)

### Provider Configuration

Providers must be configured at the root level. See `/tofu/providers.tf` for examples with placeholders:

```hcl
provider "opnsense" {
  url    = "https://opnsense.edholm.cc"
  key    = module.opnsense_secrets.items["api-key"]
  secret = module.opnsense_secrets.items["api-secret"]
}

provider "caddy" {
  host = "http://opnsense.edholm.cc:2019"
  # For SSH tunnel access, see commented examples in providers.tf
}
```

### MAC Address Limitation

The telmate/proxmox provider for LXC containers may not expose MAC addresses in outputs. You may need to:
1. Add MAC address outputs to the proxmox-container module
2. Query Proxmox API directly
3. Manually specify MAC addresses

### Security Considerations

- Store API keys/secrets in 1Password or similar secret management
- Use SSH tunneling for Caddy API access in production environments
- Configure TLS/ACME in OPNSense Caddy directly (not via Terraform)
- Implement firewall rules for Caddy listener port in OPNSense
