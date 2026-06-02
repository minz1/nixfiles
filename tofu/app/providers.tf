terraform {
  required_version = ">= 1.7"

  required_providers {
    authentik = {
      source  = "goauthentik/authentik"
      version = "~> 2026.2"
    }
    sonarr = {
      source  = "devopsarr/sonarr"
      version = "~> 3.4"
    }
    radarr = {
      source  = "devopsarr/radarr"
      version = "~> 2.3"
    }
    prowlarr = {
      source  = "devopsarr/prowlarr"
      version = "~> 3.2"
    }
    seerr = {
      source  = "josh-archer/seerr"
      version = "~> 0.19"
    }
  }

  backend "s3" {
    endpoint = "http://10.8.0.1:9000"
    bucket   = "tofu-state"
    key      = "app/terraform.tfstate"
    region   = "us-east-1"

    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    use_path_style              = true
    use_lockfile                = true
  }
}

# Token sourced from AUTHENTIK_TOKEN in secrets/tofu.env.
# URL: topology.nix nodes.minz-authentik-0.networks.incus_bridge.ip + services.authentik.port
provider "authentik" {
  url = "http://10.10.0.3:9000"
}

# API keys sourced from TF_VAR_* in secrets/tofu.env.
# URLs: topology.nix nodes.minz-arr-0.networks.incus_bridge.ip + service ports.
variable "sonarr_api_key"   { sensitive = true }
variable "radarr_api_key"   { sensitive = true }
variable "prowlarr_api_key" { sensitive = true }
variable "seerr_api_key"    { sensitive = true }
variable "nzbgeek_api_key"       { sensitive = true }
variable "torbox_api_key"        { sensitive = true }
variable "torrentio_debrid_key"  { sensitive = true }

provider "sonarr" {
  url     = "http://10.10.0.4:8989"
  api_key = var.sonarr_api_key
}

provider "radarr" {
  url     = "http://10.10.0.4:7878"
  api_key = var.radarr_api_key
}

provider "prowlarr" {
  url     = "http://10.10.0.4:9696"
  api_key = var.prowlarr_api_key
}

# URL: topology.nix nodes.minz-jellyfin-0.networks.incus_bridge.ip + services.seerr.port
provider "seerr" {
  url     = "http://10.10.0.5:5055"
  api_key = var.seerr_api_key
}
