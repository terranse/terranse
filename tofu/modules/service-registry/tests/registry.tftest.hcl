variables {
  template_dir = "./tests/fixtures"
}

run "unnamed_marker_takes_the_compose_service_name" {
  command = plan
  variables {
    bundles = ["sample"]
  }

  assert {
    condition = output.services == [
      { bundle = "sample", name = "console", port = 9000 },
      { bundle = "sample", name = "jellyfin", port = 8096 },
      { bundle = "sample", name = "seerr", port = 5055 },
    ]
    error_message = "expected console/jellyfin/seerr sorted by name; got ${jsonencode(output.services)}"
  }
}

# Each of these would have been silently mis-parsed by an earlier version.
run "parsing_edge_cases" {
  command = plan
  variables {
    bundles = ["sample"]
  }

  assert {
    condition     = length(output.services) == 3
    error_message = "unmarked ports (8920, 7359/udp) must be ignored; got ${length(output.services)} services"
  }
  assert {
    condition     = one([for s in output.services : s if s.name == "seerr"]).port == 5055
    error_message = "a quoted port must parse"
  }
  assert {
    condition     = one([for s in output.services : s if s.name == "console"]).port == 9000
    error_message = "an IP-bound mapping (127.0.0.1:9000:9000) must yield the host port, and =name must override the compose service name"
  }
}

# Annotation is optional by design: no markers means nothing is exposed,
# and that is not an error.
run "a_bundle_with_no_markers_exposes_nothing" {
  command = plan
  variables {
    bundles = ["nomarkers"]
  }

  assert {
    condition     = length(output.services) == 0
    error_message = "a bundle with no markers must yield no services, without failing"
  }
}

# Names become DNS records, so a collision must be loud rather than
# arbitrary. The message names the colliding service and its bundles.
run "duplicate_name_fails_loudly" {
  command = plan
  variables {
    bundles = ["dupe-a", "dupe-b"]
  }

  expect_failures = [
    terraform_data.registry_guard,
  ]
}
