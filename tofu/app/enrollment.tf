# ---- Per-app enrollment + group-join flows ----
#
# Each module call produces two flows:
#   <app>-enrollment  — invite-based registration, auto-joins the app group
#   <app>-join        — existing Authentik users self-service join the group
#
# To add a new app:
#   module "<app>" {
#     source                 = "./modules/app-enrollment"
#     app_name               = "<app>"
#     group_id               = authentik_group.<app>_users.id
#     join_require_invitation = true   # false for public/open-access apps
#   }

module "jellyfin" {
  source   = "./modules/app-enrollment"
  app_name = "jellyfin"
  group_id = authentik_group.jellyfin_users.id
}

# SSO source enrollment binding omitted: default-source-enrollment is a
# system-managed flow that does not accept external stage bindings. Revisit
# if an external IdP (Google, Discord) is added and invite-gating is needed.
