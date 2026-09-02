# opnsense-networking

Renders the Caddy configuration that publishes each service as
`https://<name>.edholm.cc`, and (once wired) creates the matching dnsmasq DNS
records on OPNsense.

Consumes the output of [`service-registry`](../service-registry/README.md).

## Status

Partially built. What exists today:

- **Rendering** the `services.conf` Caddy drop-in — complete and tested offline.

Not yet wired (needs an OPNsense API key and network access to the firewall):

- `opnsense_dnsmasq_host` records pointing each service name at the Caddy host.
- Deploying the rendered drop-in over SSH, validating it, and reloading Caddy.

`caddy_host` is declared but unused until that wiring lands.

## How the routing works

Each service becomes one site block in a drop-in file at
`/usr/local/etc/caddy/caddy.d/services.conf`:

```caddy
jellyfin.edholm.cc {
	tls /usr/local/etc/caddy/certificates/64c1e555e19da.pem /usr/local/etc/caddy/certificates/64c1e555e19da.key
	reverse_proxy media.edholm.cc:8096
}
```

Three things about that are load-bearing:

**The drop-in is the plugin's supported extension point.** OPNsense's os-caddy
plugin owns `/usr/local/etc/caddy/` and regenerates the Caddyfile on every
reconfigure, reboot and upgrade — but the file it generates ends with
`import /usr/local/etc/caddy/caddy.d/*.conf`. Config placed there is preserved
by design. Config pushed into Caddy's admin API on `:2019` is not: it is
runtime state, discarded on the next regeneration.

**Every site block needs its own `tls` directive.** The firewall runs Caddy
with global `auto_https off`, so Caddy will not fetch or select a certificate
on its own. The certificate is the existing ACME wildcard, managed by
OPNsense's ACME plugin and exported by refid. A block without `tls` serves no
working TLS at all.

**Exactly one upstream per block.** Caddy treats multiple upstreams as a
load-balanced pool, so one dead member produces *intermittent* 502s — roughly
one request in N, which reads as flakiness rather than misconfiguration. This
has already cost debugging time on this firewall.

Upstreams address the container by **name**, never by IP, because container
addresses move and dnsmasq registers their names automatically.

## Deploying changes

The file is the state: it is rewritten wholesale, so removing a service from
the declaration removes its route with no reconciliation logic.

When the apply hook lands it must, in order: deploy the file, run
`caddy validate`, and only then reload. A syntax error in the drop-in prevents
Caddy loading its **entire** configuration, taking every service down at once.

One trap worth knowing: `configctl caddy reload` does **not** regenerate the
Caddyfile — it runs `setup.sh` and `reloadssl` against the file already on
disk. Changing a plugin *model* entry therefore needs
`configctl template reload OPNsense/Caddy` first, or the change is saved to
`config.xml` and silently has no effect. Drop-in-only changes do not need it.

## Inputs

| Name | Description |
|---|---|
| `domain` | Base domain for service names |
| `services` | From `service-registry`, plus an `upstream` host per service |
| `cert_refid` | OPNsense certificate refid the plugin exports for Caddy |
| `caddy_host` | IP of the Caddy host; service DNS records will point here |

## Outputs

| Name | Description |
|---|---|
| `services_conf` | The rendered Caddy drop-in |
| `service_urls` | Resulting URLs, for verification |
