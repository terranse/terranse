variables {
  domain     = "edholm.cc"
  cert_refid = "64c1e555e19da"
  caddy_host = "192.168.1.1"
  services = [
    { bundle = "jellyfin", name = "jellyfin", port = 8096, upstream = "media.edholm.cc" },
    { bundle = "authentik", name = "authentik", port = 9000, upstream = "authentication.edholm.cc" },
  ]
}

run "renders_one_site_block_per_service" {
  command = plan
  assert {
    condition     = can(regex("jellyfin\\.edholm\\.cc \\{", output.services_conf))
    error_message = "must emit an FQDN site block, never a bare label"
  }
  assert {
    condition     = can(regex("reverse_proxy media\\.edholm\\.cc:8096\\n", output.services_conf))
    error_message = "must emit exactly one upstream, by name, with no trailing second upstream"
  }
  assert {
    condition     = length(regexall("tls /usr/local/etc/caddy/certificates/64c1e555e19da\\.pem", output.services_conf)) == 2
    error_message = "every site block needs an explicit tls directive because auto_https is off"
  }
  assert {
    condition     = !can(regex("192\\.168\\.", output.services_conf))
    error_message = "upstreams must be names, not IPs"
  }
  assert {
    condition     = length(regexall("reverse_proxy ", output.services_conf)) == length(var.services)
    error_message = "must emit exactly one reverse_proxy line per service, never a second one hiding elsewhere in a block"
  }
  assert {
    condition     = endswith(output.services_conf, "}\n") && !endswith(output.services_conf, "\n\n")
    error_message = "rendered file must end with exactly one trailing newline, not zero and not a blank line"
  }
}
