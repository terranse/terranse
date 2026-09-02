# service-registry

Discovers which Docker services should be published behind Caddy, by reading
marker comments out of the Ansible compose templates in
`ansible/roles/docker/templates/`.

The templates are the single source of truth for ports. Nothing is duplicated
into `.tfvars`, so a port cannot drift out of sync with the container that
publishes it.

Provider-free and offline: `tofu test` runs with no credentials.

## Exposing a service

Add `# caddy:expose` to the published port you want reachable. That's all:

```yaml
services:
  jellyfin:
    image: lscr.io/linuxserver/jellyfin:latest
    ports:
      - 8096:8096 # caddy:expose        <- published as jellyfin.edholm.cc
      - 8920:8920 # https, not proxied  <- no marker, so ignored
      - 7359:7359/udp # discovery       <- no marker, so ignored
```

**Annotation is optional.** A template with no markers exposes nothing, and
that is not an error — most containers should not be reachable from a browser.
There is no "opt out" marker to remember.

### The name

An unmarked-name marker takes the name of the **compose service** it sits
under — the `jellyfin:` key above, not the filename. That is almost always
what you want, because one template often defines several services:

```yaml
services:
  sonarr:
    ports:
      - "8989:8989" # caddy:expose      <- sonarr.edholm.cc
  radarr:
    ports:
      - "7878:7878" # caddy:expose      <- radarr.edholm.cc
```

Override it when the public name should differ from the compose service name:

```yaml
services:
  server:                               # authentik's compose service is `server`
    ports:
      - 9000:9000 # caddy:expose=authentik   <- authentik.edholm.cc, not server.edholm.cc
```

The other real override is `gluetun`, which publishes qbittorrent's web UI
because qbittorrent routes its traffic through the VPN container:

```yaml
      - 8080:8080 # caddy:expose=qbittorrent
```

### Two terms, because they are easy to confuse

| Term | Is | Example |
|---|---|---|
| **bundle** | the template filename, and what `docker_services` declares | `serverarr` (from `serverarr.yaml.j2`) |
| **compose service** | a key under `services:` inside that file | `sonarr`, `radarr`, `prowlarr`, … |

A bundle contains many compose services. Names come from the compose service.

### Choose the plain HTTP port

Caddy terminates TLS, so proxying to an HTTPS upstream means a second,
pointless TLS hop with its own trust configuration. Mark `9000`, not `9443`.

## What is checked

Two preconditions fail the plan rather than producing a quietly wrong result:

- **Duplicate names.** Each name becomes a DNS record, so a collision is
  reported with the colliding name and the bundles it came from.
- **A marker outside any compose service**, where no name can be inferred.
  Add an explicit `caddy:expose=<name>`.

## Known limitations

Accepted deliberately; each fails by ignoring the marker, never by producing a
wrong route.

- **Port ranges** (`- "8000-8010:8000-8010"`) are not matched.
- **Uppercase protocol suffixes** (`/UDP`) are not matched; lowercase is.
- The parser matches any `- HOST:CONTAINER` sequence item beneath a compose
  service, so a marker on a similarly-shaped line under `command:` or
  `environment:` would register. Nothing in this repo does that.
- **No host-port collision check.** Two services in one bundle publishing the
  same host port yield two routes to the same address; that surfaces at
  `docker compose up`, not at plan time.
- Duplicate entries in `bundles` are silently deduplicated.

Supported, though they may look like they would not be: IP-bound mappings
(`- 127.0.0.1:9000:9000` — the bind address is ignored, since Caddy reaches the
container by name), quoted ports, and trailing prose after the marker
(`# caddy:expose Http webUI`).

## Usage

```hcl
module "service_registry" {
  source = "../../modules/service-registry"

  template_dir = "${path.root}/../../../ansible/roles/docker/templates"
  bundles      = ["jellyfin", "serverarr", "nextcloud"]
}
```

Output `services` is a list of `{ bundle, name, port }`, sorted by name.
