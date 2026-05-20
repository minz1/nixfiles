terraform {
  required_version = ">= 1.7"

  required_providers {
    incus = {
      source = "lxc/incus"
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
  }
}

provider "incus" {
  generate_client_certificates = false
  accept_remote_certificate    = true

  remote {
    name    = "minz-home-vm-0"
    address = "https://10.8.0.5:8443"
  }
}
