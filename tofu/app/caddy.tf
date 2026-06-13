resource "authentik_group" "arr_admins" {
  name = "arr-admins"
}

resource "authentik_provider_proxy" "arrs" {
  name               = "arrs"
  external_host      = "https://arr.minz1.com"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  mode               = "forward_single"
}

resource "authentik_application" "arrs" {
  name              = "Arrs"
  slug              = "arrs"
  protocol_provider = authentik_provider_proxy.arrs.id
  meta_launch_url   = "blank://blank"
}

resource "authentik_policy_binding" "arrs_access" {
  target = authentik_application.arrs.uuid
  group  = authentik_group.arr_admins.id
  order  = 0
}

# Manages the embedded outpost authentik creates on first startup; import it if it already exists (see ops.md).
resource "authentik_outpost" "proxy" {
  name = "authentik Embedded Outpost"
  type = "proxy"

  protocol_providers = [
    authentik_provider_proxy.arrs.id,
    authentik_provider_proxy.media_fixer.id,
  ]

  config = jsonencode({
    authentik_host = "https://auth.minz1.com"
  })
}
