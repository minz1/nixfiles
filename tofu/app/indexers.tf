# --- Prowlarr Indexers ---
#
# Standard indexers use data sources to pull implementation/config_contract
# from the live Prowlarr instance — avoids hardcoding stale values.
# Zilean is a local Torznab service and is hardcoded accordingly.

# --- Zilean (local DMM debrid Torznab service on arr-0) ---
# Runs at 127.0.0.1:8181 on arr-0; highest priority for debrid cache hits.
resource "prowlarr_indexer" "zilean" {
  enable          = true
  name            = "Zilean"
  implementation  = "Torznab"
  config_contract = "TorznabSettings"
  protocol        = "torrent"
  app_profile_id  = 1
  priority        = 1

  fields = [
    { name = "baseUrl", text_value = "http://127.0.0.1:8181" },
    { name = "apiPath", text_value = "/torznab/api" },
    { name = "apiKey",  text_value = "" },
  ]

  lifecycle {
    ignore_changes = [fields]
  }
}

# --- Torrent indexers ---

data "prowlarr_indexer_schema" "leet"          { name = "1337x" }
data "prowlarr_indexer_schema" "yts"           { name = "YTS" }
data "prowlarr_indexer_schema" "eztv"          { name = "EZTV" }
data "prowlarr_indexer_schema" "torrentgalaxy" { name = "TorrentGalaxyClone" }
data "prowlarr_indexer_schema" "nyaa"          { name = "Nyaa.si" }
data "prowlarr_indexer_schema" "animetosho"    { name = "AnimeTosho" }

resource "prowlarr_indexer" "leet" {
  enable          = true
  name            = "1337x"
  implementation  = data.prowlarr_indexer_schema.leet.implementation
  config_contract = data.prowlarr_indexer_schema.leet.config_contract
  protocol        = data.prowlarr_indexer_schema.leet.protocol
  app_profile_id  = 1
  priority        = 25
  tags            = [prowlarr_tag.flaresolverr.id]

  fields = [
    { name = "definitionFile", text_value = "1337x" },
  ]

  lifecycle {
    ignore_changes = [fields]
  }
}

resource "prowlarr_indexer" "yts" {
  enable          = true
  name            = "YTS"
  implementation  = data.prowlarr_indexer_schema.yts.implementation
  config_contract = data.prowlarr_indexer_schema.yts.config_contract
  protocol        = data.prowlarr_indexer_schema.yts.protocol
  app_profile_id  = 1
  priority        = 25

  fields = [
    { name = "definitionFile", text_value = "yts" },
  ]

  lifecycle {
    ignore_changes = [fields]
  }
}

resource "prowlarr_indexer" "eztv" {
  enable          = true
  name            = "EZTV"
  implementation  = data.prowlarr_indexer_schema.eztv.implementation
  config_contract = data.prowlarr_indexer_schema.eztv.config_contract
  protocol        = data.prowlarr_indexer_schema.eztv.protocol
  app_profile_id  = 1
  priority        = 25
  tags            = [prowlarr_tag.flaresolverr.id]

  fields = [
    { name = "definitionFile", text_value = "eztv" },
  ]

  lifecycle {
    ignore_changes = [fields]
  }
}

resource "prowlarr_indexer" "torrentgalaxy" {
  enable          = false
  name            = "TorrentGalaxyClone"
  implementation  = data.prowlarr_indexer_schema.torrentgalaxy.implementation
  config_contract = data.prowlarr_indexer_schema.torrentgalaxy.config_contract
  protocol        = data.prowlarr_indexer_schema.torrentgalaxy.protocol
  app_profile_id  = 1
  priority        = 25

  fields = [
    { name = "definitionFile", text_value = "torrentgalaxyclone" },
    { name = "baseUrl", text_value = "https://torrentgalaxy.to" },
  ]

  lifecycle {
    ignore_changes = [fields]
  }
}

resource "prowlarr_indexer" "nyaa" {
  enable          = true
  name            = "Nyaa.si"
  implementation  = data.prowlarr_indexer_schema.nyaa.implementation
  config_contract = data.prowlarr_indexer_schema.nyaa.config_contract
  protocol        = data.prowlarr_indexer_schema.nyaa.protocol
  app_profile_id  = 1
  priority        = 25

  fields = [
    { name = "definitionFile", text_value = "nyaasi" },
  ]

  lifecycle {
    ignore_changes = [fields]
  }
}

resource "prowlarr_indexer" "animetosho" {
  enable          = true
  name            = "AnimeTosho"
  implementation  = data.prowlarr_indexer_schema.animetosho.implementation
  config_contract = data.prowlarr_indexer_schema.animetosho.config_contract
  protocol        = data.prowlarr_indexer_schema.animetosho.protocol
  app_profile_id  = 1
  priority        = 25

  fields = [
    { name = "baseUrl", text_value = "https://feed.animetosho.org" },
    { name = "apiPath", text_value = "/api" },
  ]

  lifecycle {
    ignore_changes = [fields]
  }
}

# --- Local/custom Cardigann indexers (definitions in config/prowlarr/indexers/) ---

resource "prowlarr_indexer" "torbox" {
  enable          = false
  name            = "TorBox"
  implementation  = "Cardigann"
  config_contract = "CardigannSettings"
  protocol        = "torrent"
  app_profile_id  = 1
  priority        = 1

  fields = [
    { name = "definitionFile", text_value = "torbox-torrents" },
    { name = "apikey",         sensitive_value = var.torbox_api_key },
  ]

  lifecycle {
    ignore_changes = [fields]
  }
}

resource "prowlarr_indexer" "torrentio" {
  enable          = true
  name            = "Torrentio"
  implementation  = "Cardigann"
  config_contract = "CardigannSettings"
  protocol        = "torrent"
  app_profile_id  = 1
  priority        = 25

  fields = [
    { name = "definitionFile",      text_value = "torrentio" },
    { name = "debrid_provider",     text_value = "realdebrid" },
    { name = "debrid_provider_key", sensitive_value = var.torrentio_debrid_key },
  ]

  lifecycle {
    ignore_changes = [fields]
  }
}

# Seadexerr: local Torznab service exposing SeaDex best-release anime index.
# Runs on arr-0 at 127.0.0.1:6868. SeaDex custom format in Sonarr (score 5000):
#   Settings → Custom Formats → Add → Indexer Flag Condition → Flag: Freeleech25
resource "prowlarr_indexer" "seadexerr" {
  enable          = false
  name            = "Seadexerr"
  implementation  = "Torznab"
  config_contract = "TorznabSettings"
  protocol        = "torrent"
  app_profile_id  = 1
  priority        = 25

  fields = [
    { name = "baseUrl", text_value = "http://127.0.0.1:6868" },
    { name = "apiPath", text_value = "/api" },
    { name = "apiKey",  text_value = "" },
  ]

  lifecycle {
    ignore_changes = [fields]
  }
}

# --- Usenet indexers ---

# Althub is a Newznab-compatible indexer; no schema data source needed.
resource "prowlarr_indexer" "nzbgeek" {
  enable          = true
  name            = "NZBgeek"
  implementation  = "Newznab"
  config_contract = "NewznabSettings"
  protocol        = "usenet"
  app_profile_id  = 1
  priority        = 25

  redirect = true

  fields = [
    { name = "baseUrl", text_value = "https://api.nzbgeek.info" },
    { name = "apiPath", text_value = "/api" },
    { name = "apiKey",  sensitive_value = var.nzbgeek_api_key },
  ]

  lifecycle {
    ignore_changes = [fields]
  }
}
