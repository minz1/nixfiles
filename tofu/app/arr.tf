resource "sonarr_root_folder" "tv" {
  path = "/data/library/tv"
}

resource "sonarr_media_management" "sonarr" {
  # hardlinks_copy = false: /data/downloads symlinks resolve through the
  # decypharr FUSE VFS; hardlinking across a FUSE mount to ext4 fails.
  hardlinks_copy              = false
  create_empty_folders        = false
  delete_empty_folders        = true
  enable_media_info           = true
  import_extra_files          = false
  set_permissions             = false
  skip_free_space_check       = true
  unmonitor_previous_episodes = true
  minimum_free_space          = 100
  recycle_bin_days            = 0
  chmod_folder                = "755"
  chown_group                 = "media"
  download_propers_repacks    = "preferAndUpgrade"
  episode_title_required      = "always"
  extra_file_extensions       = "srt"
  file_date                   = "none"
  recycle_bin_path            = ""
  rescan_after_refresh        = "always"
}

resource "sonarr_download_client_qbittorrent" "decypharr" {
  name     = "decypharr"
  enable   = true
  priority = 1
  host     = "127.0.0.1"
  port     = 8282
  tv_category = "tv-sonarr"
}

resource "sonarr_download_client_sabnzbd" "decypharr_usenet" {
  name        = "decypharr Usenet"
  enable      = true
  priority    = 1
  host        = "127.0.0.1"
  port        = 8282
  url_base    = "/sabnzbd"
  username    = "http://127.0.0.1:8989/sonarr"
  password    = var.sonarr_api_key
  tv_category = "sonarr"
}

resource "radarr_root_folder" "movies" {
  path = "/data/library/movies"
}

resource "radarr_media_management" "radarr" {
  copy_using_hardlinks                        = false
  create_empty_movie_folders                  = false
  delete_empty_folders                        = true
  enable_media_info                           = true
  import_extra_files                          = false
  set_permissions_linux                       = false
  skip_free_space_check_when_importing        = true
  minimum_free_space_when_importing           = 100
  recycle_bin_cleanup_days                    = 0
  chmod_folder                                = "755"
  chown_group                                 = "media"
  download_propers_and_repacks                = "preferAndUpgrade"
  extra_file_extensions                       = "srt"
  file_date                                   = "none"
  recycle_bin                                 = ""
  rescan_after_refresh                        = "always"
  auto_unmonitor_previously_downloaded_movies = false
  auto_rename_folders                         = false
  paths_default_static                        = false
}

resource "radarr_download_client_qbittorrent" "decypharr" {
  name           = "decypharr"
  enable         = true
  priority       = 1
  host           = "127.0.0.1"
  port           = 8282
  movie_category = "radarr"
}

resource "radarr_download_client_sabnzbd" "decypharr_usenet" {
  name           = "decypharr Usenet"
  enable         = true
  priority       = 1
  host           = "127.0.0.1"
  port           = 8282
  url_base       = "/sabnzbd"
  username       = "http://127.0.0.1:7878/radarr"
  password       = var.radarr_api_key
  movie_category = "radarr"
}

resource "prowlarr_tag" "flaresolverr" {
  label = "flaresolverr"
}

resource "prowlarr_indexer_proxy_flaresolverr" "flaresolverr" {
  name            = "flaresolverr"
  host            = "http://127.0.0.1:8191"
  request_timeout = 60
  tags            = [prowlarr_tag.flaresolverr.id]
}

# Seadex: marks Freeleech25 releases; set score +5000 manually in Sonarr quality profiles.
resource "sonarr_custom_format" "seadex" {
  include_custom_format_when_renaming = false
  name                                = "Seadex"

  specifications = [
    {
      name           = "Freeleech25"
      implementation = "IndexerFlagSpecification"
      negate         = false
      required       = false
      value          = "8"
    }
  ]
}

resource "prowlarr_application_sonarr" "sonarr" {
  name         = "Sonarr"
  sync_level   = "addOnly"
  base_url     = "http://127.0.0.1:8989/sonarr"
  prowlarr_url = "http://127.0.0.1:9696/prowlarr"
  api_key      = var.sonarr_api_key
  sync_categories = [
    5000, # TV
    5010, # TV/WEB-DL
    5030, # TV/HD
    5040, # TV/SD
    5045, # TV/UHD
    5050, # TV/Other
  ]
  anime_sync_categories = [5070]
}

resource "prowlarr_application_radarr" "radarr" {
  name         = "Radarr"
  sync_level   = "addOnly"
  base_url     = "http://127.0.0.1:7878/radarr"
  prowlarr_url = "http://127.0.0.1:9696/prowlarr"
  api_key      = var.radarr_api_key
  sync_categories = [
    2000, # Movies
    2010, # Movies/Foreign
    2020, # Movies/Other
    2030, # Movies/SD
    2040, # Movies/HD
    2045, # Movies/UHD
    2050, # Movies/BluRay
    2060, # Movies/3D
    2070, # Movies/DVD
    2080, # Movies/WEB-DL
  ]
}
