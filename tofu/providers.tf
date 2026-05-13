terraform {
  required_version = ">= 1.0"

  required_providers {
    incus = {
      source  = "terraform-linux/incus"
      version = "~> 0.1"
    }
  }
}

provider "incus" {
  # Connects to the Incus daemon on the home VM over WireGuard.
  # Set INCUS_REMOTE=home-vm in your environment, or configure
  # the remote with:
  #
  #   incus remote add home-vm 10.8.0.5:8443
  #
  # The provider reads from ~/.config/incus/config.yml by default.
}
