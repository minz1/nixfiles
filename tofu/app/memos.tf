resource "authentik_group" "memos_users" {
  name = "memos-users"
}

resource "authentik_provider_oauth2" "memos" {
  name               = "memos"
  client_id          = "memos"
  client_type        = "confidential"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  property_mappings  = data.authentik_property_mapping_provider_scope.oidc.ids
  allowed_redirect_uris = [
    {
      matching_mode = "strict"
      url           = "https://memos.minz1.com/auth/callback"
    }
  ]
}

resource "authentik_application" "memos" {
  name              = "Memos"
  slug              = "memos"
  protocol_provider = authentik_provider_oauth2.memos.id
}

resource "authentik_policy_binding" "memos_users_access" {
  target = authentik_application.memos.uuid
  group  = authentik_group.memos_users.id
  order  = 0
}

module "memos" {
  source                  = "./modules/app-enrollment"
  app_name                = "memos"
  group_id                = authentik_group.memos_users.id
  join_require_invitation = false
}

output "memos_client_secret" {
  value     = authentik_provider_oauth2.memos.client_secret
  sensitive = true
}
