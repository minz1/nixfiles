data "authentik_flow" "default_authorization" {
  slug = "default-provider-authorization-implicit-consent"
}

data "authentik_flow" "default_invalidation" {
  slug = "default-provider-invalidation-flow"
}

data "authentik_property_mapping_provider_scope" "oidc" {
  managed_list = [
    "goauthentik.io/providers/oauth2/scope-openid",
    "goauthentik.io/providers/oauth2/scope-email",
    "goauthentik.io/providers/oauth2/scope-profile",
  ]
}

resource "authentik_provider_oauth2" "grafana" {
  name               = local.contracts.oidc.grafana.clientId
  client_id          = local.contracts.oidc.grafana.clientId
  client_type        = "confidential"
  grant_types        = ["authorization_code", "refresh_token"]
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  property_mappings  = data.authentik_property_mapping_provider_scope.oidc.ids
  allowed_redirect_uris = [for u in local.contracts.oidc.grafana.redirectUris : {
    matching_mode     = "strict"
    redirect_uri_type = "authorization"
    url               = u
  }]
}

resource "authentik_application" "grafana" {
  name              = "Grafana"
  slug              = "grafana"
  protocol_provider = authentik_provider_oauth2.grafana.id
}

resource "authentik_group" "grafana_admins" {
  name = local.contracts.oidc.grafana.adminGroup
}

resource "authentik_policy_binding" "grafana_access" {
  target = authentik_application.grafana.uuid
  group  = authentik_group.grafana_admins.id
  order  = 0
}

output "grafana_client_secret" {
  value     = authentik_provider_oauth2.grafana.client_secret
  sensitive = true
}
