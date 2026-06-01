# --- Seerr app configuration ---
#
# Post-deploy sequence before running app-apply:
#   1. Complete Seerr setup wizard: http://10.10.0.5:5055
#      - Choose Jellyfin, enter localhost:8096, log in with jellyfin admin credentials
#   2. From Seerr Settings → get API key → TF_VAR_seerr_api_key in tofu.env
#   3. From Seerr Settings → Jellyfin → copy the API key Seerr created → TF_VAR_jellyfin_api_key
#   4. From each arr: Settings → General → API key → TF_VAR_{sonarr,radarr}_api_key
#   5. just tofu app-plan && just tofu app-apply

# seerr_jellyfin_settings omitted: provider always sends read-only `name` field
# causing API 400. The wizard already configured the Jellyfin connection and
# API key correctly; no tofu management needed for this singleton.

resource "seerr_sonarr_server" "default" {
  name                  = "Sonarr"
  hostname              = "10.10.0.4"
  port                  = 8989
  use_ssl               = false
  api_key               = var.sonarr_api_key
  active_directory      = "/data/library/tv"
  is_default            = true
  enable_season_folders = true
  quality_profile_id    = 7 # WEB-2160p (Combined)
  extra_payload_json    = jsonencode({
    activeAnimeProfileId = 8 # [Anime] Remux-1080p
    animeSeriesType      = "anime"
  })
}

resource "seerr_radarr_server" "default" {
  name               = "Radarr"
  hostname           = "10.10.0.4"
  port               = 7878
  use_ssl            = false
  api_key            = var.radarr_api_key
  active_directory   = "/data/library/movies"
  is_default         = true
  quality_profile_id = 7 # Remux 2160p (Combined)
}

# --- Seerr OIDC in Authentik ---
# Provisioned now so the client_id/slug is stable.
# Activate in 5g: set main.oidcLogin=true via Seerr Settings UI,
# and configure oidc.providers with the values below.
# issuerUrl = "http://10.10.0.3:9000/application/o/seerr/"
# clientId  = "seerr"
# clientSecret = output.seerr_client_secret (store in sops before activating)

resource "authentik_provider_oauth2" "seerr" {
  name               = "seerr"
  client_id          = "seerr"
  client_type        = "confidential"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  property_mappings  = data.authentik_property_mapping_provider_scope.oidc.ids
  # Internal URL for phase 5f; update to https://seerr.<domain>/login in 5g.
  allowed_redirect_uris = [
    {
      matching_mode = "strict"
      url           = "http://10.10.0.5:5055/login"
    }
  ]
}

resource "authentik_application" "seerr" {
  name              = "Seerr"
  slug              = "seerr"
  protocol_provider = authentik_provider_oauth2.seerr.id
}

output "seerr_client_secret" {
  value     = authentik_provider_oauth2.seerr.client_secret
  sensitive = true
}
