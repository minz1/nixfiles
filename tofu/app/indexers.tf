# Public indexers built from Prowlarr's own definition schemas. fields only seed the indexer on
# create (ignore_changes below), so later edits in the Prowlarr UI stick.
locals {
  schema_indexers = {
    leet = {
      name         = "1337x"
      priority     = 25
      flaresolverr = true
      fields       = [{ name = "definitionFile", text_value = "1337x" }]
    }
    yts = {
      name         = "YTS"
      priority     = 25
      flaresolverr = false
      fields       = [{ name = "definitionFile", text_value = "yts" }]
    }
    eztv = {
      name         = "EZTV"
      priority     = 25
      flaresolverr = true
      fields       = [{ name = "definitionFile", text_value = "eztv" }]
    }
    nyaa = {
      name         = "Nyaa.si"
      priority     = 5
      flaresolverr = false
      fields       = [{ name = "definitionFile", text_value = "nyaasi" }]
    }
    animetosho = {
      name         = "AnimeTosho"
      priority     = 5
      flaresolverr = false
      fields = [
        { name = "baseUrl", text_value = "https://animetosho.org" },
        { name = "apiPath", text_value = "/feed/api" },
      ]
    }
    animetosho_usenet = {
      name         = "AnimeTosho (Usenet)"
      priority     = 5
      flaresolverr = false
      fields = [
        { name = "baseUrl", text_value = "https://animetosho.org" },
        { name = "apiPath", text_value = "/feed/api" },
      ]
    }
    subsplease = {
      name         = "SubsPlease"
      priority     = 5
      flaresolverr = false
      fields       = []
    }
    knaben = {
      name         = "Knaben"
      priority     = 25
      flaresolverr = false
      fields       = []
    }
    tpb = {
      name         = "The Pirate Bay"
      priority     = 25
      flaresolverr = false
      fields       = [{ name = "definitionFile", text_value = "thepiratebay" }]
    }
    uindex = {
      name         = "Uindex"
      priority     = 25
      flaresolverr = true
      fields       = [{ name = "definitionFile", text_value = "uindex" }]
    }
  }
}

data "prowlarr_indexer_schema" "public" {
  for_each = local.schema_indexers
  name     = each.value.name
}

resource "prowlarr_indexer" "public" {
  for_each = local.schema_indexers

  enable          = true
  name            = each.value.name
  implementation  = data.prowlarr_indexer_schema.public[each.key].implementation
  config_contract = data.prowlarr_indexer_schema.public[each.key].config_contract
  protocol        = data.prowlarr_indexer_schema.public[each.key].protocol
  redirect        = data.prowlarr_indexer_schema.public[each.key].protocol == "usenet"
  app_profile_id  = 1
  priority        = each.value.priority
  tags            = each.value.flaresolverr ? [prowlarr_tag.flaresolverr.id] : null
  fields          = each.value.fields

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
  priority        = 1

  fields = [
    { name = "definitionFile", text_value = "torrentio" },
    { name = "debrid_provider", text_value = "realdebrid" },
    { name = "debrid_provider_key", sensitive_value = var.torrentio_debrid_key },
  ]

  lifecycle {
    ignore_changes = [fields]
  }
}

resource "prowlarr_indexer" "seadexerr" {
  enable          = true
  name            = "Seadexerr"
  implementation  = "Torznab"
  config_contract = "TorznabSettings"
  protocol        = "torrent"
  app_profile_id  = 1
  priority        = 25

  fields = [
    { name = "baseUrl", text_value = "http://127.0.0.1:6868" },
    { name = "apiPath", text_value = "/api" },
    { name = "apiKey", text_value = "" },
  ]

  lifecycle {
    ignore_changes = [fields]
  }
}

resource "prowlarr_indexer" "zilean" {
  enable          = true
  name            = "Zilean"
  implementation  = "Torznab"
  config_contract = "TorznabSettings"
  protocol        = "torrent"
  app_profile_id  = 1
  priority        = 25

  fields = [
    { name = "baseUrl", text_value = "http://127.0.0.1:8181/torznab" },
    { name = "apiPath", text_value = "/api" },
    { name = "apiKey", text_value = "" },
  ]

  lifecycle {
    ignore_changes = [fields]
  }
}

resource "prowlarr_indexer" "comet" {
  enable          = true
  name            = "Comet"
  implementation  = "Torznab"
  config_contract = "TorznabSettings"
  protocol        = "torrent"
  app_profile_id  = 1
  priority        = 25

  fields = [
    { name = "baseUrl", text_value = "http://127.0.0.1:8000/torznab" },
    { name = "apiPath", text_value = "/api" },
    { name = "apiKey", text_value = "" },
  ]

  lifecycle {
    ignore_changes = [fields]
  }
}

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
    { name = "apiKey", sensitive_value = var.nzbgeek_api_key },
  ]

  lifecycle {
    ignore_changes = [fields]
  }
}
