terraform {
  required_version = ">= 1.7"

  required_providers {
    incus = {
      source = "lxc/incus"
    }
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }

  backend "s3" {
    endpoint = "http://10.8.0.1:9000"
    bucket   = "tofu-state"
    key      = "incus/terraform.tfstate"
    region   = "us-east-1"

    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    use_path_style              = true
    use_lockfile                = true
  }
}

provider "aws" {
  region                      = "us-east-1"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  s3_use_path_style           = true

  # Endpoint sourced from topology.nix: nodes.minz-vultr-nix-0.{networks.mgmt.ip, services.rustfs.ports[0]}
  endpoints {
    s3 = "http://10.8.0.1:9000"
  }
}

provider "incus" {
  generate_client_certificates = false
  accept_remote_certificate    = true

  # Address/port sourced from topology.nix: nodes.minz-home-nix-0.{networks.mgmt.ip, services.incus.port}
  remote {
    name    = "minz-home-nix-0"
    address = "https://10.8.0.5:8443"
  }

  # Address/port sourced from topology.nix: nodes.minz-vultr-nix-0.{networks.mgmt.ip, services.rustfs.ports[0]}
  remote {
    name     = "nixos-bootstrap-registry"
    address  = "http://10.8.0.1:9000/incus-images"
    protocol = "simplestreams"
  }
}
