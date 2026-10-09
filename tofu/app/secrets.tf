data "sops_file" "arr" {
  source_file = "${path.root}/../../secrets/shared/arr.yaml"
}

data "sops_file" "seerr" {
  source_file = "${path.root}/../../secrets/shared/seerr.yaml"
}

data "sops_file" "decypharr" {
  source_file = "${path.root}/../../secrets/shared/decypharr.yaml"
}

data "sops_file" "minecraft" {
  source_file = "${path.root}/../../secrets/shared/minecraft.yaml"
}
