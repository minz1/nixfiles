resource "seerr_api_object" "jellyfin_settings" {
  path          = "/api/v1/settings/jellyfin"
  read_method   = "GET"
  create_method = "POST"
  update_method = "POST"
  skip_delete   = true

  request_body_json = jsonencode({
    ip               = "127.0.0.1"
    port             = 8096
    useSsl           = false
    apiKey           = var.jellyfin_api_key
    externalHostname = "https://jellyfin.minz1.com"
  })
}

resource "seerr_main_settings" "main" {
  local_login  = false
  trust_proxy  = true
}

resource "seerr_sonarr_server" "default" {
  name                  = "Sonarr"
  hostname              = "10.10.0.4"
  port                  = 8989
  base_url              = "/sonarr"
  use_ssl               = false
  api_key               = var.sonarr_api_key
  active_directory      = "/data/library/tv"
  is_default            = true
  enable_season_folders = true
  quality_profile_id    = 7 # WEB-2160p (Combined)
  extra_payload_json    = jsonencode({
    activeAnimeProfileId = 8 # Remux-1080p Anime
  })
}

resource "seerr_radarr_server" "default" {
  name               = "Radarr"
  hostname           = "10.10.0.4"
  port               = 7878
  base_url           = "/radarr"
  use_ssl            = false
  api_key            = var.radarr_api_key
  active_directory   = "/data/library/movies"
  is_default         = true
  quality_profile_id = 7 # Remux 2160p (Combined)
}

resource "authentik_provider_oauth2" "seerr" {
  name               = "seerr"
  client_id          = "seerr"
  client_type        = "confidential"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  property_mappings  = data.authentik_property_mapping_provider_scope.oidc.ids
  allowed_redirect_uris = [
    {
      matching_mode = "strict"
      url           = "https://seerr.minz1.com/login"
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

resource "seerr_notification_email" "main" {
  enabled      = true
  embed_poster = false
  notification_types = [
    "MEDIA_APPROVED",
    "MEDIA_AVAILABLE",
    "MEDIA_DECLINED",
    "MEDIA_AUTO_APPROVED",
  ]
  email = {
    email_from  = "noreply@minz1.com"
    smtp_host   = "smtp.resend.com"
    smtp_port   = 587
    require_tls = true
    auth_user   = "resend"
    auth_pass   = var.seerr_smtp_password
    sender_name = "Seerr"
  }
}

resource "seerr_notification_discord" "main" {
  enabled      = true
  embed_poster = true
  notification_types = [
    "MEDIA_APPROVED",
    "MEDIA_AVAILABLE",
    "MEDIA_DECLINED",
    "MEDIA_AUTO_APPROVED",
  ]
  discord = {
    webhook_url     = var.seerr_discord_webhook
    enable_mentions = false
  }
}
