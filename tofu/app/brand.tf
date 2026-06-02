resource "authentik_brand" "default" {
  domain        = "authentik-default"
  default       = true
  branding_title = "authentik"

  branding_logo    = "/static/dist/assets/icons/icon_left_brand.svg"
  branding_favicon = "/static/dist/assets/icons/icon.png"

  # Built-in Authentik default flows — UUIDs stable per install
  flow_authentication = "863ab675-ac71-4c21-8962-216f45c3bf7c"
  flow_invalidation   = "3d7ced42-58ba-4d71-a5c0-ace100ca2955"
  flow_user_settings  = "81ceedd5-2207-41a4-9a10-0e14cf42d4d4"

  flow_recovery = authentik_flow.recovery.uuid
}
