# op inject template -- references only, never values. Rendered on the laptop
# and piped over SSH, so no 1Password token has to exist on the box.
#
#   just secrets htpc /var/lib/home-player-secrets/env root
#
# Re-running is the whole rotation procedure.
SONARR_API_KEY={{ op://HomeNetwork/Servarr/sonarr-token }}
RADARR_API_KEY={{ op://HomeNetwork/Servarr/radarr-token }}
SEERR_API_KEY={{ op://HomeNetwork/Seerr/api_key }}
SUNSHINE_PASSWORD={{ op://Infrastructure/Sunshine Gaming/password }}
JELLYFIN_API_KEY={{ op://HomeNetwork/Home Player Jellyfin token/password }}
