resource "authentik_group" "media_fixer_admins" {
  name = "media-fixer-admins"
}

resource "authentik_provider_proxy" "media_fixer" {
  name               = "media-fixer"
  external_host      = "https://admin.minz1.com"
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  mode               = "forward_single"
}

resource "authentik_application" "media_fixer" {
  name              = "Media Fixer"
  slug              = "media-fixer"
  protocol_provider = authentik_provider_proxy.media_fixer.id
  meta_launch_url   = "https://admin.minz1.com/media"
}

resource "authentik_policy_binding" "media_fixer_access" {
  target = authentik_application.media_fixer.uuid
  group  = authentik_group.media_fixer_admins.id
  order  = 0
}
