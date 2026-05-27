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
