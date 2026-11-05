# op inject template -- references only, never values. Rendered on the laptop
# and piped over SSH, so nothing secret touches the repo or the Nix store.
#
#   just secrets htpc /var/lib/home-player-secrets/env root
#
# Re-running is the whole rotation procedure. The backend reads this as an
# EnvironmentFile and fills the ${env:NAME} references in its config with it.
SONARR_API_KEY={{ op://HomeNetwork/Servarr/sonarr-token }}
RADARR_API_KEY={{ op://HomeNetwork/Servarr/radarr-token }}
SEERR_API_KEY={{ op://HomeNetwork/Seerr/api_key }}
SUNSHINE_PASSWORD={{ op://Infrastructure/Sunshine Gaming/password }}
HA_TOKEN={{ op://HomeNetwork/HomeAssistant HTPC token/password }}
JELLYFIN_API_KEY={{ op://HomeNetwork/Home Player Jellyfin token/password }}
