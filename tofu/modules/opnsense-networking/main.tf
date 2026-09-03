terraform {
  required_version = ">= 1.6.0"
  required_providers {
    opnsense = {
      source  = "browningluke/opnsense"
      version = "~> 0.16"
    }
  }
}

locals {
  services_conf = templatefile("${path.module}/templates/services.conf.tftpl", {
    services   = var.services
    domain     = var.domain
    cert_refid = var.cert_refid
  })
}

# One DNS record per exposed service, all pointing at Caddy rather than at the
# container that backs the service. Caddy is what terminates TLS and routes by
# name, so the service name must resolve to it, not to the upstream.
resource "opnsense_dnsmasq_host" "service" {
  for_each = { for s in var.services : s.name => s }

  hostname     = each.key
  domain       = var.domain
  ip_addresses = [var.caddy_host]
  description  = "terranse: ${each.key} -> Caddy"
}

# Static reservations. `hardware_addresses` is what makes this a DHCP
# reservation rather than a bare DNS record; dnsmasq must be the DHCP server
# for it to have any effect.
resource "opnsense_dnsmasq_host" "reservation" {
  for_each = var.reservations

  hostname           = each.key
  domain             = var.domain
  ip_addresses       = [each.value.ip]
  hardware_addresses = [each.value.mac]
  description        = "terranse: ${each.key} reservation"
}

# Ship the drop-in to the firewall. The file goes over ssh STDIN rather than
# being embedded in a remote command string: the content contains braces, tabs
# and newlines, and making that survive HCL escaping plus two shells is exactly
# the kind of quoting that fails silently and leaves no file behind.
#
# The order below is load-bearing: a syntax error in this one file stops Caddy
# loading its ENTIRE configuration, taking every service down at once. So the
# previous file is kept and restored if `caddy validate` rejects the new one,
# and the reload only happens after validation passes.
resource "terraform_data" "deploy_services_conf" {
  triggers_replace = [sha256(local.services_conf)]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    # OPNsense root's login shell is csh, and `ssh host <cmd>` hands <cmd> to
    # that login shell -- csh mangles multi-line quoted scripts and then exits
    # 0, so failures look like successes. The script therefore travels over
    # STDIN (`sh -s`), where csh never sees it, and the file content rides
    # along base64-encoded so no quoting has to survive the trip.
    command = <<-EOT
      set -euo pipefail
      ssh -p ${var.ssh_port} ${var.ssh_target} /bin/sh -s <<'REMOTE'
      set -e
      D=/usr/local/etc/caddy/caddy.d
      printf '%s' '${base64encode(local.services_conf)}' | openssl enc -base64 -d -A > $D/services.conf.new
      if [ ! -s $D/services.conf.new ]; then
        echo "refusing to deploy an empty drop-in" >&2
        rm -f $D/services.conf.new
        exit 1
      fi
      if [ -f $D/services.conf ]; then cp -p $D/services.conf $D/services.conf.bak; fi
      mv $D/services.conf.new $D/services.conf
      if ! /usr/local/bin/caddy validate --config /usr/local/etc/caddy/Caddyfile --adapter caddyfile > /tmp/caddyval.log 2>&1; then
        echo "caddy validate REJECTED the drop-in; restoring previous" >&2
        tail -5 /tmp/caddyval.log >&2
        if [ -f $D/services.conf.bak ]; then mv $D/services.conf.bak $D/services.conf; else rm -f $D/services.conf; fi
        exit 1
      fi
      rm -f $D/services.conf.bak
      configctl caddy reload
      echo "DEPLOY_OK site_blocks=$(grep -c 'edholm.cc {' $D/services.conf)"
      REMOTE
    EOT
  }
}
