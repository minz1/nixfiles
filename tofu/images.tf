resource "incus_image" "bootstrap" {
  source_file = {
    data_path     = "../result/nixos.qcow2"
    metadata_path = "../result/metadata.tar.xz"
  }

  alias {
    name        = "nixos-bootstrap"
  }

  lifecycle {
    create_before_destroy = true
  }
}
