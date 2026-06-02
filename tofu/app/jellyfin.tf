data "authentik_flow" "default_authentication" {
  slug = "default-authentication-flow"
}

resource "authentik_group" "jellyfin_users" {
  name = "jellyfin-users"
}

# Service account used by the Jellyfin LDAP plugin to bind and search.
# Password is sops-managed: TF_VAR_ldap_bind_password in secrets/tofu.env.
# Only set on resource creation — rotation requires: tofu taint authentik_user.ldap_bind
resource "authentik_user" "ldap_bind" {
  username = "ldap-bind"
  name     = "LDAP Bind (Jellyfin)"
  type     = "service_account"
  path     = "goauthentik.io/service-accounts"
  password = var.ldap_bind_password
}

resource "authentik_provider_ldap" "jellyfin" {
  name        = "jellyfin-ldap"
  bind_flow   = data.authentik_flow.default_authentication.id
  unbind_flow = data.authentik_flow.default_invalidation.id
  base_dn     = "dc=ldap,dc=goauthentik,dc=io"
}

resource "authentik_application" "jellyfin" {
  name              = "Jellyfin"
  slug              = "jellyfin"
  protocol_provider = authentik_provider_ldap.jellyfin.id
}

resource "authentik_policy_binding" "jellyfin_ldap_users" {
  target = authentik_application.jellyfin.uuid
  group  = authentik_group.jellyfin_users.id
  order  = 0
}

resource "authentik_policy_binding" "jellyfin_ldap_bind" {
  target = authentik_application.jellyfin.uuid
  user   = tonumber(authentik_user.ldap_bind.id)
  order  = 10
}

resource "authentik_outpost" "ldap" {
  name               = "ldap-outpost"
  type               = "ldap"
  protocol_providers = [authentik_provider_ldap.jellyfin.id]
}
