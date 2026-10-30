data "authentik_flow" "default_authentication" {
  slug = "default-authentication-flow"
}

resource "authentik_group" "jellyfin_users" {
  name = "jellyfin-users"
}

# Jellyfin LDAP plugin bind/search account; password is TF_VAR_ldap_bind_password in secrets/tofu.env; rotate via `tofu taint authentik_user.ldap_bind`.

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
  groups   = []
  roles    = [authentik_rbac_role.ldap_searcher.id]
}

data "authentik_certificate_key_pair" "ldap_outpost" {
  name = "ldap-outpost"
}

data "authentik_stage" "default_password" {
  name = "default-authentication-password"
}

data "authentik_stage" "default_login" {
  name = "default-authentication-login"
}

# MFA-free bind flow; require_outpost refuses it to anything but the LDAP outpost's token.
resource "authentik_flow" "ldap_bind" {
  name           = "LDAP Bind"
  slug           = "ldap-bind"
  title          = "LDAP Bind"
  designation    = "authentication"
  authentication = "require_outpost"
}

resource "authentik_stage_identification" "ldap_bind" {
  name           = "ldap-identification"
  user_fields    = ["username"]
  password_stage = data.authentik_stage.default_password.id
}

resource "authentik_stage_deny" "ldap_bind" {
  name = "ldap-bind-deny"
}

# Without MFA here, other accounts (akadmin) would get a password oracle: deny them like a wrong password.
resource "authentik_policy_expression" "ldap_bind_denied" {
  name              = "ldap-bind-denied"
  execution_logging = false
  expression        = <<-EOT
    user = request.context.get("pending_user")
    if not user or not user.pk:
        return True
    return not (user.username == "${authentik_user.ldap_bind.username}" or ak_is_group_member(user, name="${authentik_group.jellyfin_users.name}"))
  EOT
}

resource "authentik_flow_stage_binding" "ldap_bind_identification" {
  target = authentik_flow.ldap_bind.uuid
  stage  = authentik_stage_identification.ldap_bind.id
  order  = 10
}

resource "authentik_flow_stage_binding" "ldap_bind_deny" {
  target               = authentik_flow.ldap_bind.uuid
  stage                = authentik_stage_deny.ldap_bind.id
  order                = 15
  evaluate_on_plan     = false
  re_evaluate_policies = true
}

resource "authentik_policy_binding" "ldap_bind_deny" {
  policy         = authentik_policy_expression.ldap_bind_denied.id
  target         = authentik_flow_stage_binding.ldap_bind_deny.id
  order          = 0
  failure_result = true
}

resource "authentik_flow_stage_binding" "ldap_bind_login" {
  target = authentik_flow.ldap_bind.uuid
  stage  = data.authentik_stage.default_login.id
  order  = 20
}

resource "authentik_provider_ldap" "jellyfin" {
  name        = "jellyfin-ldap"
  bind_flow   = authentik_flow.ldap_bind.uuid
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
