locals {
  jellyfin_host = "127.0.0.1"
  jellyfin_port = 8096
}

resource "sonarr_notification" "jellyfin" {
  name            = "Jellyfin"
  implementation  = "MediaBrowser"
  config_contract = "MediaBrowserSettings"

  on_grab                            = false
  on_download                        = true
  on_upgrade                         = true
  on_import_complete                 = true
  on_rename                          = true
  on_series_delete                   = false
  on_episode_file_delete             = false
  on_episode_file_delete_for_upgrade = false
  on_health_issue                    = false
  on_application_update              = false
  include_health_warnings            = false

  host           = local.jellyfin_host
  port           = local.jellyfin_port
  api_key        = var.jellyfin_api_key
  use_ssl        = false
  update_library = true
  notify         = false
}

resource "radarr_notification" "jellyfin" {
  name            = "Jellyfin"
  implementation  = "MediaBrowser"
  config_contract = "MediaBrowserSettings"

  on_grab                          = false
  on_download                      = true
  on_upgrade                       = true
  on_rename                        = true
  on_movie_added                   = false
  on_movie_delete                  = false
  on_movie_file_delete             = false
  on_movie_file_delete_for_upgrade = false
  on_health_issue                  = false
  on_application_update            = false
  include_health_warnings          = false

  host           = local.jellyfin_host
  port           = local.jellyfin_port
  api_key        = var.jellyfin_api_key
  use_ssl        = false
  update_library = true
  notify         = false
}

resource "sonarr_notification_webhook" "decypharr_import" {
  name   = "decypharr-import"
  url    = "http://127.0.0.1:8282/webhooks/arr/sonarr"
  method = 1

  on_grab                            = false
  on_download                        = true
  on_upgrade                         = true
  on_import_complete                 = false
  on_rename                          = false
  on_series_add                      = false
  on_series_delete                   = false
  on_episode_file_delete             = false
  on_episode_file_delete_for_upgrade = false
  on_health_issue                    = false
  on_health_restored                 = false
  on_application_update              = false
  on_manual_interaction_required     = false
  include_health_warnings            = false

  username = "arr"
  password = data.sops_file.decypharr.data["decypharr_api_token"]
}

resource "radarr_notification_webhook" "decypharr_import" {
  name   = "decypharr-import"
  url    = "http://127.0.0.1:8282/webhooks/arr/radarr"
  method = 1

  on_grab                          = false
  on_download                      = true
  on_upgrade                       = true
  on_rename                        = false
  on_movie_added                   = false
  on_movie_delete                  = false
  on_movie_file_delete             = false
  on_movie_file_delete_for_upgrade = false
  on_health_issue                  = false
  on_health_restored               = false
  on_application_update            = false
  on_manual_interaction_required   = false
  include_health_warnings          = false

  username = "arr"
  password = data.sops_file.decypharr.data["decypharr_api_token"]
}
