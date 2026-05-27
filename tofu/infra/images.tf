resource "incus_image" "bootstrap" {
  source_image = {
    remote = "nixos-bootstrap-registry"
    name   = "nixos-bootstrap"
    type   = "virtual-machine"
  }

  alias {
    name = "nixos-bootstrap"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "incus_image" "bootstrap_container" {
  source_image = {
    remote = "nixos-bootstrap-registry"
    name   = "nixos-bootstrap-container"
    type   = "container"
  }

  alias {
    name = "nixos-bootstrap-container"
  }

  lifecycle {
    create_before_destroy = true
  }
}
