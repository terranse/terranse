# Automatic DNS + Caddy Reverse Proxy Integration

## Context

Services run as Docker containers inside LXC containers on Proxmox. Each service should automatically get a subdomain (`jellyfin.edholm.cc`), a DNS entry, and a Caddy reverse proxy entry. Caddy runs on OPNsense via the os-caddy plugin, with a wildcard TLS cert managed by OPNsense's ACME plugin. The existing `opnsense-networking` module was started but never activated — it uses a `conradludgate/caddy` provider that turns out to be unviable (transient config, no TLS support).

## Approach: Caddyfile drop-in via SSH

Tofu generates a `services.conf` Caddyfile snippet and deploys it to `/usr/local/etc/caddy/caddy.d/` on OPNsense via SSH. The os-caddy plugin natively imports `*.conf` files from this directory. TLS is handled automatically by the existing ACME wildcard cert — no TLS config needed in the Caddyfile.

## Data Flow

```
configurations.tfvars          deployment main.tf              opnsense-networking module
─────────────────────          ──────────────────              ──────────────────────────
hosts.lxcs.docker_services  →  local.lxc_services (computed)  →  service_registry expands bundles
                                                               →  generates DNS overrides (Unbound)
                                                               →  generates services.conf (Caddyfile)
                                                               →  SSH deploys to OPNsense caddy.d/
```

**No changes to `configurations.tfvars`** for the base case. Port overrides and aliases are optional.

## Changes

### 1. New file: `tofu/modules/opnsense-networking/locals.tf`

Service registry mapping bundle names to HTTP sub-services with default ports:

```hcl
locals {
  service_registry = {
    jellyfin  = [{ name = "jellyfin", port = 8096 }, { name = "jellyseerr", port = 5055 }]
    serverarr = [
      { name = "prowlarr", port = 9696 }, { name = "qbittorrent", port = 8080 },
      { name = "radarr", port = 7878 },   { name = "sonarr", port = 8989 },
      { name = "lidarr", port = 8686 },   { name = "lazylibrarian", port = 5299 },
    ]
    nextcloud  = [{ name = "nextcloud", port = 8080 }]
    vikunja    = [{ name = "vikunja", port = 3456 }]
    authentik  = [{ name = "authentik", port = 9000 }]
    "dls-server" = [{ name = "fastapi-dls", port = 443 }]
  }
}
```

Plus the flattening logic:
- Expand `lxc_services` (map of LXC name → bundle names) through `service_registry`
- Apply `port_overrides`
- Merge `aliases` into the final map
- Result: `local.all_proxy_entries` — a map of subdomain → {lxc_name, port}

### 2. Rewrite: `tofu/modules/opnsense-networking/variables.tf`

Replace current variables with:
- `domain` (string) — base domain
- `lxc_services` (map(list(string))) — LXC name → service bundle names
- `lxc_containers` (map(object({ip_address, mac_address}))) — for DHCP/DNS (keep existing, optional)
- `kea_subnet_id` (string) — for DHCP reservations (keep existing, optional)
- `port_overrides` (map(number), default={}) — optional per-service port overrides
- `aliases` (map(string), default={}) — optional alias subdomain → target service name
- `opnsense_host` (string) — OPNsense SSH host for deploying Caddyfile
- `opnsense_ip` (string) — OPNsense internal IP (for DNS overrides pointing service subdomains to Caddy)

Drop: `docker_services`, `caddy_listen_port`

### 3. Rewrite: `tofu/modules/opnsense-networking/main.tf`

**Keep:** DHCP reservations and LXC DNS overrides (unchanged, still use `browningluke/opnsense`)

**Add:** DNS overrides for each service subdomain → OPNsense IP:
```hcl
resource "opnsense_unbound_domain_override" "service_dns" {
  for_each    = local.all_proxy_entries
  domain      = "${each.key}.${var.domain}"
  server      = var.opnsense_ip
  description = "Service ${each.key} -> Caddy"
  enabled     = true
}
```

**Replace** `caddy_server` resource with Caddyfile drop-in:
```hcl
resource "null_resource" "caddy_config" {
  triggers = { config_hash = sha256(local.caddyfile_content) }

  provisioner "file" {
    content     = local.caddyfile_content
    destination = "/usr/local/etc/caddy/caddy.d/services.conf"
    connection { type = "ssh", host = var.opnsense_host, ... }
  }

  provisioner "remote-exec" {
    inline = ["configctl caddy reconfigure"]
    connection { ... }
  }
}
```

Generated Caddyfile:
```
jellyfin.edholm.cc {
  reverse_proxy media.edholm.cc:8096
}
radarr.edholm.cc {
  reverse_proxy media.edholm.cc:7878
}
# ... etc
cloud.edholm.cc {
  reverse_proxy colab.edholm.cc:8080
}
```

**Drop:** `conradludgate/caddy` provider requirement

### 4. Update: `tofu/modules/opnsense-networking/outputs.tf`

Replace `caddy_server_names` output with:
- `service_urls` — map of service name → public URL
- `caddyfile_content` — the generated Caddyfile (for debugging)

Keep: `dhcp_reservations`, `dns_overrides`

### 5. Update: `tofu/providers.tf`

- Remove `caddy` provider block and requirement
- Keep `opnsense` provider (uncomment when ready)

### 6. Update: deployment `main.tf` files (edholm + sectrinet)

Add computed local and module call:
```hcl
locals {
  lxc_services = {
    for lxc_name, lxc_config in merge([
      for host_key, host in var.hosts : {
        for lxc_key, lxc in try(host.lxcs, {}) : lxc_key => lxc
      }
    ]...) : lxc_name => [
      for svc in try(lxc_config.docker_services, []) : svc.name
    ]
    if length(try(lxc_config.docker_services, [])) > 0
  }
}

module "opnsense-networking" {
  source = "../../modules/opnsense-networking"

  domain       = var.domain
  lxc_services = local.lxc_services
  opnsense_ip  = var.gateway  # Caddy runs on OPNsense which is typically the gateway
  opnsense_host = ...         # SSH connection details

  # Optional
  aliases = try(var.aliases, {})
  port_overrides = try(var.port_overrides, {})
}
```

### 7. Update: deployment `defaults.tf` files

Add optional variables for `aliases` and `port_overrides` with empty defaults.

## Files Modified

| File | Action |
|------|--------|
| `tofu/modules/opnsense-networking/locals.tf` | **New** — service registry + flattening logic |
| `tofu/modules/opnsense-networking/variables.tf` | **Rewrite** — new variable interface |
| `tofu/modules/opnsense-networking/main.tf` | **Rewrite** — service DNS + Caddyfile drop-in |
| `tofu/modules/opnsense-networking/outputs.tf` | **Update** — new outputs |
| `tofu/modules/opnsense-networking/README.md` | **Update** — reflect new design |
| `tofu/providers.tf` | **Update** — remove caddy provider |
| `tofu/deployments/edholm/main.tf` | **Update** — add lxc_services local + module call |
| `tofu/deployments/edholm/defaults.tf` | **Update** — add aliases/port_overrides vars |
| `tofu/deployments/sectrinet/main.tf` | **Update** — same as edholm |
| `tofu/deployments/sectrinet/defaults.tf` | **Update** — same as edholm |

## Verification

1. `tofu validate` on both deployments (with `-backend=false` since providers aren't configured yet)
2. `just validate-tofu` runs the validation loop
3. Inspect generated `caddyfile_content` output to verify correct service expansion
4. Manual: verify `caddy.d/` import works on a test OPNsense instance

## Open Questions / Notes

- **SSH connection to OPNsense**: The `null_resource` provisioner needs SSH credentials. These should come from 1Password secrets, similar to the Proxmox provider credentials.
- **LXC hostname resolution**: The Caddyfile uses `media.edholm.cc:8096` as upstreams. This assumes Kea DHCP + Unbound integration on OPNsense makes LXC hostnames resolvable. If not, the DHCP reservation part of the module (which creates explicit Unbound entries for each LXC) handles this.
- **Caddy TLS**: The os-caddy plugin's ACME config handles TLS for all domains in the Caddyfile automatically. No TLS directives needed in `services.conf`.
- **Host/VM domain names**: The existing `opnsense_unbound_domain_override.lxc_dns` resource already creates DNS entries for each LXC (`media.edholm.cc`, etc.). VMs would need similar treatment when they're wired up.
