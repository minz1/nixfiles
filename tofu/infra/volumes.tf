resource "incus_storage_volume" "persist" {
  for_each = local.nixos_vms

  name         = "${each.key}-persist"
  pool         = "default"
  content_type = "block"

  config = {
    size = try(each.value.incus.persist_size, "100GiB")
  }
}
