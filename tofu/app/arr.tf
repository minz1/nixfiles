# --- Sonarr ---

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
  # decypharr uses the category to route downloads to the right subfolder
  tv_category = "tv-sonarr"
}

# --- Radarr ---

resource "radarr_root_folder" "movies" {
  path = "/data/library/movies"
}

resource "radarr_media_management" "radarr" {
  hardlinks_copy           = false
  create_empty_folders     = false
  delete_empty_folders     = true
  enable_media_info        = true
  import_extra_files       = false
  set_permissions          = false
  skip_free_space_check    = true
  minimum_free_space       = 100
  recycle_bin_days         = 0
  chmod_folder             = "755"
  chown_group              = "media"
  download_propers_repacks = "preferAndUpgrade"
  extra_file_extensions    = "srt"
  file_date                = "none"
  recycle_bin_path         = ""
  rescan_after_refresh     = "always"
  auto_unmonitor_previously_downloaded_movies = false
}

resource "radarr_download_client_qbittorrent" "decypharr" {
  name            = "decypharr"
  enable          = true
  priority        = 1
  host            = "127.0.0.1"
  port            = 8282
  movie_category  = "radarr"
}

# --- Prowlarr ---

# Flaresolverr runs as a container on arr-0, localhost-only.
resource "prowlarr_indexer_proxy_flaresolverr" "flaresolverr" {
  name        = "flaresolverr"
  host        = "http://127.0.0.1:8191"
  request_timeout = 60
}

# Wire Prowlarr → Sonarr. TV sync categories (5xxx = TV).
resource "prowlarr_application_sonarr" "sonarr" {
  name         = "Sonarr"
  sync_level   = "addOnly"
  base_url     = "http://127.0.0.1:8989"
  prowlarr_url = "http://127.0.0.1:9696"
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

# Wire Prowlarr → Radarr. Movie sync categories (2xxx = Movies).
resource "prowlarr_application_radarr" "radarr" {
  name         = "Radarr"
  sync_level   = "addOnly"
  base_url     = "http://127.0.0.1:7878"
  prowlarr_url = "http://127.0.0.1:9696"
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
