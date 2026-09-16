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
# the gpu-manager config template and the virtiofs-attach task consume:
# { gaming = { vmid = N, tier = "game", mounts = [...] } }. The mounts ride
# along so the host play can publish each dataset as a directory mapping and
# attach it — the guest cannot do either for itself.
locals {
  gaming_vms_by_host = {
    for host_key, mod in module.proxmox-vm : host_key => {
      for name, id in mod.vm_ids : name => merge({
        vmid   = id
        mounts = try(var.hosts[host_key].vms[name].mounts, [])
        # gpu-manager arbitrates the card by tier, so it has to travel with
        # the VMID: without it every VM would look like a gaming VM and the
        # AI VM could never be told apart from the one it displaces.
        tier = try(var.hosts[host_key].vms[name].gpu_tier, "game")
        },
        # The daemon probes Sunshine on this address to decide when a claim is
        # really satisfied. Without it `sunshine_reachable` is permanently
        # false and the wait-for-stream step never runs, so a handover reports
        # done the moment the VM powers on, well before the stream is up.
        #
        # Game tier only. observe() dials this address on EVERY pass for any
        # VM that has one, and an AI VM runs no Sunshine -- with *.edholm.cc
        # resolving to the WAN IP and no hairpin NAT, that is a dial timeout
        # every five seconds for nothing. StepWaitSunshine is game-only
        # anyway.
        #
        # A `for … if` comprehension rather than a conditional: HCL requires a
        # conditional's arms to have identical types, and `{host = string}` and
        # `{}` do not. Same reason as hosts_wired below.
        { for k, v in { host = "${name}.${var.domain}" } : k => v
          if try(var.hosts[host_key].vms[name].gpu_tier, "game") == "game" }
      )
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

  # Bare-metal hosts that declared a MAC. Nothing derives these -- a physical
  # NIC's address is a fact, so the tfvars entry is the source of truth for
  # both the reservation below and CI's wakeonlan step.
  #
  # The filter tests the SHAPE, not merely presence. A machine whose NIC has
  # not been read yet carries an explicit placeholder in configurations.tfvars
  # (see the htpc entry there, and keep the two comments in sync). A
  # presence-only test -- `try(host.mac, null) != null` -- treats that
  # placeholder as a real address: a full opnsense_dnsmasq_host reservation is
  # planned with a garbage hardware_addresses, nothing anywhere in this chain
  # validates MAC shape, and every unrelated apply on this deployment (a new
  # container, a Caddy route) then either errors at the OPNsense API or writes
  # a junk reservation. That blocks the whole deployment on a step for a
  # machine that does not physically exist yet. Requiring a well-formed
  # address instead makes an unfilled placeholder simply produce no
  # reservation, which is exactly what it means.
  host_macs = {
    for host_key, host in var.hosts : host_key => host.mac
    if can(regex("^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$", try(host.mac, "")))
  }

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

# A reservation is keyed by name and a name is a DNS record, so a container
# and a bare-metal host sharing one would silently overwrite each other's
# address. merge() would pick the host's and say nothing.
resource "terraform_data" "reservation_name_uniqueness_guard" {
  input = sort(concat(keys(local.lxc_macs), keys(local.host_macs)))

  lifecycle {
    precondition {
      condition     = length(setintersection(keys(local.lxc_macs), keys(local.host_macs))) == 0
      error_message = "A bare-metal host and an LXC share a name, so their DHCP reservations would collide: ${jsonencode(setintersection(keys(local.lxc_macs), keys(local.host_macs)))}"
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

  reservations = merge(
    {
      for name, ip in var.lxc_reserved_ips : name => {
        mac = local.lxc_macs[name]
        ip  = ip
      } if contains(keys(local.lxc_macs), name)
    },
    {
      for name, ip in var.host_reserved_ips : name => {
        mac = local.host_macs[name]
        ip  = ip
      } if contains(keys(local.host_macs), name)
    },
  )
}
