variables {
  template_dir = "../../../ansible/roles/docker/templates"
  bundles      = ["jellyfin", "serverarr", "nextcloud", "authentik", "vikunja", "gluetun", "mosquitto", "gitlab-runner", "homeassistant", "zigbee2mqtt", "zwave-js-ui"]
}

run "all_declared_bundles_resolve" {
  command = plan

  # Full expected set of (bundle, name, port), sorted by name (the module's
  # own sort order). This pins down every field of every service, not just
  # the count and two spot checks: a wrong port on any of the ten services
  # not previously asserted (e.g. nextcloud, vikunja, qbittorrent, prowlarr,
  # radarr, lidarr, lazylibrarian, bazarr, jellyfin, seerr) now fails here
  # too. `bundle` is included deliberately: a later task maps bundle -> LXC
  # to build the upstream address, so a wrong bundle would route to the
  # wrong container.
  #
  # On failure, OpenTofu's assertion diff pinpoints exactly which row and
  # which field diverged (unchanged rows/attributes are collapsed), so no
  # extra bespoke error message is needed to identify the culprit.
  assert {
    condition = output.services == [
      { bundle = "authentik", name = "authentik", port = 9000 },
      { bundle = "serverarr", name = "bazarr", port = 6767 },
      { bundle = "jellyfin", name = "jellyfin", port = 8096 },
      { bundle = "serverarr", name = "lazylibrarian", port = 5299 },
      { bundle = "serverarr", name = "lidarr", port = 8686 },
      { bundle = "nextcloud", name = "nextcloud", port = 8080 },
      { bundle = "serverarr", name = "prowlarr", port = 9696 },
      { bundle = "gluetun", name = "qbittorrent", port = 8080 },
      { bundle = "serverarr", name = "radarr", port = 7878 },
      { bundle = "jellyfin", name = "seerr", port = 5055 },
      { bundle = "serverarr", name = "sonarr", port = 8989 },
      { bundle = "vikunja", name = "vikunja", port = 3456 },
    ]
    error_message = "output.services does not match the expected set of 12 (bundle, name, port) rows above; see the assertion diff for the specific row/field that diverged"
  }
}
