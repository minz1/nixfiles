data "authentik_flow" "default_authentication" {
  slug = "default-authentication-flow"
}

resource "authentik_group" "jellyfin_users" {
  name = "jellyfin-users"
}

# Jellyfin LDAP plugin bind/search account; password is TF_VAR_ldap_bind_password in secrets/tofu.env; rotate via `tofu taint authentik_user.ldap_bind`.
data "authentik_group" "readonly" {
  name = "authentik Read-only"
}

# Role granting search_full_directory on the jellyfin LDAP provider — without it, CanSearch=false and the bind user can only see itself.
resource "authentik_rbac_role" "ldap_searcher" {
  name = "LDAP Directory Searcher"
}

resource "authentik_rbac_permission_role" "ldap_search_permission" {
  role       = authentik_rbac_role.ldap_searcher.id
  permission = "authentik_providers_ldap.search_full_directory"
  model      = "authentik_providers_ldap.ldapprovider"
  object_id  = authentik_provider_ldap.jellyfin.id
}

resource "authentik_user" "ldap_bind" {
  username = "ldap-bind"
  name     = "LDAP Bind (Jellyfin)"
  type     = "service_account"
  path     = "goauthentik.io/service-accounts"
  password = var.ldap_bind_password
  groups   = [data.authentik_group.readonly.id]
  roles    = [authentik_rbac_role.ldap_searcher.id]
}

data "authentik_certificate_key_pair" "ldap_outpost" {
  name = "ldap-outpost"
}

resource "authentik_provider_ldap" "jellyfin" {
  name        = "jellyfin-ldap"
  bind_flow   = data.authentik_flow.default_authentication.id
  unbind_flow = data.authentik_flow.default_invalidation.id
  base_dn     = "dc=ldap,dc=goauthentik,dc=io"
  search_mode = "cached"
  certificate = data.authentik_certificate_key_pair.ldap_outpost.id
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
