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
  local_login = false
  trust_proxy = true
}

resource "seerr_sonarr_server" "default" {
  name                  = "Sonarr"
  hostname              = "10.10.0.7"
  port                  = 8989
  base_url              = "/sonarr"
  use_ssl               = false
  api_key               = data.sops_file.arr.data["sonarr_api_key"]
  active_directory      = "/data/library/tv"
  is_default            = true
  enable_season_folders = true
  quality_profile_id    = 7 # WEB-2160p (Combined)
  extra_payload_json = jsonencode({
    activeAnimeProfileId = 8 # Remux-1080p Anime
  })
  lifecycle { ignore_changes = [quality_profile_name, active_anime_directory, anime_tags, tags] }
}

resource "seerr_radarr_server" "default" {
  name               = "Radarr"
  hostname           = "10.10.0.7"
  port               = 7878
  base_url           = "/radarr"
  use_ssl            = false
  api_key            = data.sops_file.arr.data["radarr_api_key"]
  active_directory   = "/data/library/movies"
  is_default         = true
  quality_profile_id = 7 # Remux 2160p (Combined)
  lifecycle { ignore_changes = [quality_profile_name, tags] }
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
      matching_mode     = "strict"
      redirect_uri_type = "authorization"
      url               = "https://seerr.minz1.com/login"
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

    secure            = false
    ignore_tls        = false
    allow_self_signed = false
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

resource "seerr_notification_webhook" "media_fixer" {
  enabled      = true
  embed_poster = false
  notification_types = [
    "ISSUE_CREATED",
    "ISSUE_REOPENED",
  ]
  webhook = {
    webhook_url = "https://minz-services-0.internal/ingest/seerr"
    auth_header = "Bearer ${data.sops_file.seerr.data["seerr_webhook_secret"]}"
    json_payload = jsonencode({
      notification_type     = "{{notification_type}}"
      subject               = "{{subject}}"
      message               = "{{message}}"
      issue_id              = "{{issue_id}}"
      issue_type            = "{{issue_type}}"
      issue_status          = "{{issue_status}}"
      media_type            = "{{media_type}}"
      media_tmdbid          = "{{media_tmdbid}}"
      media_jellyfinMediaId = "{{media_jellyfinMediaId}}"
      reported_by           = "{{reportedBy_username}}"
    })
  }
}
