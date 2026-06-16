module "jellyfin" {
  source   = "./modules/app-enrollment"
  app_name = "jellyfin"
  group_id = authentik_group.jellyfin_users.id
}

module "homelab" {
  source   = "./modules/app-enrollment"
  app_name = "homelab"
}

