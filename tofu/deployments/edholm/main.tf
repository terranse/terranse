module "proxmox-lxc" {
  for_each = {
    for host_key, host in var.hosts : host_key => host
    if try(host.lxcs, null) != null
  }
  source = "../../modules/proxmox-container"

  ansible_root     = local.ansible_root
  host             = each.key
  configuration    = each.value.lxcs
  ssh_key          = var.ssh_key
  domain           = var.domain
  gateway          = var.gateway
  storage_pool     = try(each.value.storage_pool, "FastStorage")
  host_ssh_address = try(each.value.ansible_host, each.key)
}

module "proxmox-vm" {
  for_each = {
    for host_key, host in var.hosts : host_key => host
    if try(host.vms, null) != null
  }
  source = "../../modules/proxmox-vm"

  host          = each.key
  proxmox_node  = try(each.value.proxmox_node, each.key)
  storage_pool  = try(each.value.storage_pool, "FastStorage")
  configuration = each.value.vms
  ssh_key       = var.ssh_key
  domain        = var.domain
}

# Inject the gaming VMs' live VMIDs (from the proxmox-vm module) into the
# gpu-manager role's vars, so it never hardcodes a VMID. Shape matches what
# vm-map.json.j2 and the virtiofs-attach task consume:
# { gaming = { vmid = N, mounts = [...] } }. The mounts ride along so the host
# play can publish each dataset as a directory mapping and attach it — the guest
# cannot do either for itself.
locals {
  gaming_vms_by_host = {
    for host_key, mod in module.proxmox-vm : host_key => {
      for name, id in mod.vm_ids : name => {
        vmid   = id
        mounts = try(var.hosts[host_key].vms[name].mounts, [])
      }
    }
  }

  # Give every role a `vars` map and fold the VMIDs into gpu-manager's, both
  # unconditionally. HCL requires a conditional's two arms to have *identical*
  # types, and host_roles is a heterogeneous tuple — `drivers` declares `vars`,
  # `gpu-manager` declares none — so `r.name == "gpu-manager" ? merge(r, {vars =
  # ...}) : r` is a type error ("attribute vars absent in the false value"). The
  # `if` inside the map comprehension selects instead of branching, which keeps
  # one type throughout.
  hosts_wired = {
    for host_key, host in var.hosts : host_key => merge(host, {
      host_roles = [
        for r in try(host.host_roles, []) : merge(r, {
          vars = merge(
            try(r.vars, {}),
            {
              for k, v in { gaming_vms = try(local.gaming_vms_by_host[host_key], {}) } : k => v
              if r.name == "gpu-manager" && contains(keys(local.gaming_vms_by_host), host_key)
            }
          )
        })
      ]
    })
  }
}

module "ansible-wiring" {
  source          = "../../modules/ansible-wiring"
  ansible_root    = local.ansible_root
  deployment_name = "edholm"
  deployment_path = "../tofu/deployments/edholm"
  hosts           = local.hosts_wired
  ansible_plays = flatten(concat(
    [for instance in module.proxmox-lxc : instance.ansible_plays],
    [for instance in module.proxmox-vm : instance.ansible_plays],
  ))
}

# ---------------------------------------------------------------------------
# Service registration: DNS names + Caddy routes for every exposed container.
# ---------------------------------------------------------------------------

locals {
  # Every LXC name across every host, for the uniqueness guard below.
  all_lxc_names = flatten([
    for host_key, host in var.hosts : keys(try(host.lxcs, {}))
  ])

  # Deterministic MACs, flattened across hosts. `merge` would silently drop a
  # duplicate name, which is exactly what the guard prevents.
  lxc_macs = merge([
    for host_key, mod in module.proxmox-lxc : mod.lxc_mac_addresses
  ]...)

  # Which container runs which compose bundle, so a service's upstream can be
  # addressed by container name rather than by an address that moves.
  bundle_to_container = merge(flatten([
    for host_key, host in var.hosts : [
      for lxc_name, lxc in try(host.lxcs, {}) : {
        for svc in try(lxc.docker_services, []) : svc.name => lxc_name
      }
    ]
  ])...)
}

# MACs derive from the container name ALONE, and proxmox-container is
# instantiated once per host — so two containers sharing a name on different
# hosts would be handed identical MACs on one L2 segment. Nothing inside a
# single module instance can see that, so the check has to live here.
resource "terraform_data" "lxc_name_uniqueness_guard" {
  input = local.all_lxc_names

  lifecycle {
    precondition {
      condition     = length(local.all_lxc_names) == length(distinct(local.all_lxc_names))
      error_message = "LXC names must be unique across ALL hosts, because deterministic MACs are derived from the name alone. Duplicates: ${jsonencode([for n in distinct(local.all_lxc_names) : n if length([for m in local.all_lxc_names : m if m == n]) > 1])}"
    }
  }
}

module "service_registry" {
  source = "../../modules/service-registry"

  template_dir = "${path.root}/../../../ansible/roles/docker/templates"
  bundles      = keys(local.bundle_to_container)
}

module "opnsense_networking" {
  source = "../../modules/opnsense-networking"

  domain     = var.domain
  caddy_host = var.caddy_host
  cert_refid = var.opnsense_cert_refid

  # Upstreams address the container by name; dnsmasq registers those from the
  # DHCP reservations below, so the name is stable even though the address is
  # handed out by DHCP.
  services = [
    for s in module.service_registry.services : {
      bundle   = s.bundle
      name     = s.name
      port     = s.port
      upstream = "${local.bundle_to_container[s.bundle]}.${var.domain}"
    }
  ]

  reservations = {
    for name, ip in var.lxc_reserved_ips : name => {
      mac = local.lxc_macs[name]
      ip  = ip
    } if contains(keys(local.lxc_macs), name)
  }
}
