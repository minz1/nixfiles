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
    sops = {
      source  = "carlpett/sops"
      version = ">= 0.7"
    }
  }

  backend "s3" {
    endpoint = "http://10.8.0.1:9000"
    bucket   = "tofu-state"
    key      = "infra/terraform.tfstate"
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

  # RustFS on vultr-nix-0 (mgmt IP, RUSTFS_ADDRESS port in hosts/minz-vultr-nix-0)
  endpoints {
    s3 = "http://10.8.0.1:9000"
  }
}

provider "incus" {
  generate_client_certificates = false
  accept_remote_certificate    = true

  # Incus API on home-nix-0 (mgmt IP, core.https_address port in hosts/minz-home-nix-0)
  remote {
    name    = "minz-home-nix-0"
    address = "https://10.8.0.5:8443"
  }

  # RustFS on vultr-nix-0 (mgmt IP, RUSTFS_ADDRESS port in hosts/minz-vultr-nix-0)
  remote {
    name     = "nixos-bootstrap-registry"
    address  = "http://10.8.0.1:9000/incus-images"
    protocol = "simplestreams"
  }
}

provider "sops" {}

