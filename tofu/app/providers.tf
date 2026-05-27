terraform {
  required_version = ">= 1.7"

  required_providers {
    authentik = {
      source  = "goauthentik/authentik"
      version = "~> 2026.2"
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

# Token sourced from AUTHENTIK_TOKEN in secrets/rustfs-tofu.env.
# URL: topology.nix nodes.minz-authentik-0.networks.incus_bridge.ip + services.authentik.port
provider "authentik" {
  url = "http://10.10.0.3:9000"
}
