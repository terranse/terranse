terraform {
  required_version = ">= 1.6.0"
}

# Discovers which Docker services should be published behind Caddy by reading
# `# caddy:expose` markers out of the Ansible compose templates.
#
# Annotation is OPTIONAL: a bundle with no markers simply exposes nothing.
# See README.md for the convention.

locals {
  # ---- regexes -------------------------------------------------------------
  # Matched per line, so `$` means end-of-line and no (?m) flag is needed.
  # NOTE: OpenTofu uses RE2, which has no lookahead — the trailing
  # `([ \t]|$)` stands in for a word boundary. A bare `\b` would not do:
  # it also matches `caddy:expose:seerr`, which would silently register
  # under the wrong name.

  # A compose service key: exactly two spaces of indent, then `name:`.
  svc_re = "^  ([a-zA-Z0-9_-]+):[ \t]*$"

  # A marker, with or without an explicit name override.
  marker_re   = "#[ \t]*caddy:expose(=[A-Za-z0-9_-]+)?([ \t]|$)"
  override_re = "#[ \t]*caddy:expose=([A-Za-z0-9_-]+)([ \t]|$)"

  # A published port. The optional IPv4 group requires dots so it cannot
  # swallow the host port of a plain `HOST:CONTAINER` mapping. Bind address
  # is deliberately ignored: Caddy reaches the container by name.
  port_re = "^[ \t]*-[ \t]*\"?(?:(?:[0-9]+\\.){3}[0-9]+:)?([0-9]+):[0-9]+"

  # ---- parsing -------------------------------------------------------------
  lines = {
    for b in var.bundles : b => split("\n", file("${var.template_dir}/${b}.yaml.j2"))
  }

  # Every marker line, with the indices of the compose service keys above it.
  marked = flatten([
    for b, ls in local.lines : [
      for i, l in ls : {
        bundle    = b
        line      = l
        port      = tonumber(regex(local.port_re, l)[0])
        override  = try(regex(local.override_re, l)[0], null)
        preceding = [for j, sl in ls : j if j < i && can(regex(local.svc_re, sl))]
      }
      if can(regex(local.marker_re, l)) && can(regex(local.port_re, l))
    ]
  ])

  # A marker sitting outside any compose service has no name to inherit.
  orphaned = [for m in local.marked : m.line if length(m.preceding) == 0]

  # An unnamed marker takes the name of the compose service it sits under —
  # `preceding` is ascending, so its last element is the nearest one above.
  services_unsorted = [
    for m in local.marked : {
      bundle = m.bundle
      port   = m.port
      name = (
        m.override != null
        ? m.override
        : regex(local.svc_re, local.lines[m.bundle][element(reverse(m.preceding), 0)])[0]
      )
    }
    if length(m.preceding) > 0
  ]

  # Sorted by name, without one() — which raises rather than reporting a
  # useful error when two services collide. The %08d index breaks ties in
  # original order; the space separator sorts below every character a
  # service name may contain.
  sort_keys = {
    for i, s in local.services_unsorted : "${s.name} ${format("%08d", i)}" => s
  }
  services = [for k in sort(keys(local.sort_keys)) : local.sort_keys[k]]

  duplicate_names = {
    for n in distinct([for s in local.services_unsorted : s.name]) :
    n => [for s in local.services_unsorted : s.bundle if s.name == n]
    if length([for s in local.services_unsorted : s if s.name == n]) > 1
  }
  duplicate_message = join("; ", [
    for n, bundles in local.duplicate_names : "${n} (from bundles: ${join(", ", bundles)})"
  ])
}

resource "terraform_data" "registry_guard" {
  input = local.services

  lifecycle {
    precondition {
      condition     = length(local.duplicate_names) == 0
      error_message = "Duplicate exposed service name(s) — each must be unique across all bundles, since each becomes a DNS name: ${local.duplicate_message}"
    }

    precondition {
      condition     = length(local.orphaned) == 0
      error_message = "caddy:expose marker(s) not inside any compose service, so no name can be inferred — add an explicit `caddy:expose=<name>`: ${join(" | ", local.orphaned)}"
    }
  }
}
