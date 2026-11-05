# op inject template -- references only, never values. Rendered on the laptop
# and piped over SSH, so nothing secret touches the repo or the Nix store.
#
#   just secrets nixhost /var/lib/nixhost-secrets/env root
#
# Re-running is the whole rotation procedure. The nightly unit reads this as
# an EnvironmentFile: HA_TOKEN for the stale-build alert, and the cache signing
# key, which the unit moves into a private file before anything else runs.
HA_TOKEN={{ op://HomeNetwork/HomeAssistant HTPC token/password }}
NIX_SIGNING_KEY={{ op://HomeNetwork/HTPC cache signing key/password }}
