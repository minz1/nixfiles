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
