# --- Arr forward-auth via authentik proxy ---

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

# Embedded proxy outpost — handles forward-auth for Caddy at
# /outpost.goauthentik.io/auth/caddy. The embedded outpost is auto-created
# by authentik on first startup; this resource manages it declaratively.
#
# First apply: if authentik's auto-created outpost conflicts, import it first:
#   sops exec-env secrets/tofu.env \
#     'tofu -chdir=tofu/app import authentik_outpost.proxy <uuid>'
# UUID is visible in authentik Admin → System → Outposts → authentik Embedded Outpost
resource "authentik_outpost" "proxy" {
  name = "authentik Embedded Outpost"
  type = "proxy"

  protocol_providers = [authentik_provider_proxy.arrs.id]

  config = jsonencode({
    authentik_host = "https://auth.minz1.com"
  })
}
