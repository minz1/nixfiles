resource "authentik_provider_oauth2" "forgejo" {
  name               = "forgejo"
  client_id          = "forgejo"
  client_type        = "confidential"
  grant_types        = ["authorization_code", "refresh_token"]
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  property_mappings  = data.authentik_property_mapping_provider_scope.oidc.ids
  allowed_redirect_uris = [
    {
      matching_mode     = "strict"
      redirect_uri_type = "authorization"
      url               = "https://git.minz1.com/user/oauth2/authentik/callback"
    }
  ]
}

resource "authentik_application" "forgejo" {
  name              = "Forgejo"
  slug              = "forgejo"
  protocol_provider = authentik_provider_oauth2.forgejo.id
}

resource "authentik_group" "forgejo_users" {
  name = "forgejo-users"
}

resource "authentik_group" "forgejo_admins" {
  name = "forgejo-admins"
}

resource "authentik_policy_binding" "forgejo_users" {
  target = authentik_application.forgejo.uuid
  group  = authentik_group.forgejo_users.id
  order  = 0
}

resource "authentik_policy_binding" "forgejo_admins" {
  target = authentik_application.forgejo.uuid
  group  = authentik_group.forgejo_admins.id
  order  = 1
}

output "forgejo_client_secret" {
  value     = authentik_provider_oauth2.forgejo.client_secret
  sensitive = true
}
