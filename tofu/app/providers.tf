terraform {
  required_version = ">= 1.7"

  required_providers {
    authentik = {
      source  = "goauthentik/authentik"
      version = "~> 2026.5"
    }
    sonarr = {
      source  = "devopsarr/sonarr"
      version = "~> 3.5"
    }
    radarr = {
      source  = "devopsarr/radarr"
      version = "~> 2.5"
    }
    prowlarr = {
      source  = "devopsarr/prowlarr"
      version = "~> 3.2"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.4"
    }
    seerr = {
      source = "josh-archer/seerr"
      # Exact pin: upgrades are reviewed by hand (0.19.3 -> 2.2.1 on 2026-10-19; the upstream signing key is fixed since 2.x).
      version = "2.2.1"
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
provider "authentik" {
  url = "https://10.10.0.3:9443"
}

variable "nzbgeek_api_key" { sensitive = true }
variable "torrentio_debrid_key" { sensitive = true }

provider "sonarr" {
  url     = "https://10.10.0.7/sonarr"
  api_key = data.sops_file.arr.data["sonarr_api_key"]
}

provider "radarr" {
  url     = "https://10.10.0.7/radarr"
  api_key = data.sops_file.arr.data["radarr_api_key"]
}

provider "prowlarr" {
  url     = "https://10.10.0.7/prowlarr"
  api_key = ephemeral.sops_file.prowlarr.data["prowlarr_api_key"]
}

provider "seerr" {
  url     = "https://10.10.0.7"
  api_key = ephemeral.sops_file.seerr_api.data["seerr_api_key"]
}
