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
    seerr = {
      source = "josh-archer/seerr"
      # Exact pin: fetching any release fresh (0.19.5 through 1.1.0-rc.2, tested)
      # fails "authentication signature from unknown issuer" on `tofu init -upgrade`,
      # a broken/rotated signing key upstream — not specific to any one version.
      # 0.19.3 only works because it's already trusted via .terraform.lock.hcl
      # (trust-on-first-use, no fresh fetch needed). Revisit once upstream re-signs.
      version = "0.19.3"
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

# API keys sourced from TF_VAR_* in secrets/tofu.env.
# URLs: topology.nix nodes.minz-media-0.networks.incus_bridge.ip + service ports.
variable "sonarr_api_key"   { sensitive = true }
variable "radarr_api_key"   { sensitive = true }
variable "prowlarr_api_key" { sensitive = true }
variable "seerr_api_key"    { sensitive = true }
variable "nzbgeek_api_key"       { sensitive = true }
variable "torbox_api_key"        { sensitive = true }
variable "torrentio_debrid_key"  { sensitive = true }

provider "sonarr" {
  url     = "https://10.10.0.7/sonarr"
  api_key = var.sonarr_api_key
}

provider "radarr" {
  url     = "https://10.10.0.7/radarr"
  api_key = var.radarr_api_key
}

provider "prowlarr" {
  url     = "https://10.10.0.7/prowlarr"
  api_key = var.prowlarr_api_key
}

provider "seerr" {
  url     = "https://10.10.0.7"
  api_key = var.seerr_api_key
}
