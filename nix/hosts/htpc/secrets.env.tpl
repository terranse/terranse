# op inject template -- references only, never values. Rendered on the laptop
# and piped over SSH, so no 1Password token has to exist on the box.
#
#   just secrets htpc /var/lib/home-player-secrets/env root
#
# Re-running is the whole rotation procedure.
JELLYFIN_API_KEY={{ op://HomeNetwork/Jellyfin/api_key }}
JELLYFIN_USER_ID={{ op://HomeNetwork/Jellyfin/user_id }}
SONARR_API_KEY={{ op://HomeNetwork/Sonarr/api_key }}
RADARR_API_KEY={{ op://HomeNetwork/Radarr/api_key }}
SEERR_API_KEY={{ op://HomeNetwork/Seerr/api_key }}
SUNSHINE_USERNAME={{ op://Infrastructure/Sunshine Gaming/username }}
SUNSHINE_PASSWORD={{ op://Infrastructure/Sunshine Gaming/password }}
