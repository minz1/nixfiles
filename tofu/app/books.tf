resource "authentik_group" "book_users" {
  name = "book-users"
}

data "authentik_certificate_key_pair" "oidc_signing" {
  name = "authentik Self-signed Certificate"
}

resource "authentik_property_mapping_provider_scope" "abs_roles" {
  name       = "Audiobookshelf roles"
  scope_name = "abs_roles"
  expression = <<-EOT
    groups = [group.name for group in request.user.ak_groups.all()]
    if "${authentik_group.arr_admins.name}" in groups:
        return {"abs_roles": ["admin"]}
    if "${authentik_group.book_users.name}" in groups:
        return {"abs_roles": ["user"]}
    return {"abs_roles": []}
  EOT
}

resource "authentik_provider_oauth2" "audiobookshelf" {
  name               = local.contracts.oidc.audiobookshelf.clientId
  client_id          = local.contracts.oidc.audiobookshelf.clientId
  client_secret      = data.sops_file.audiobookshelf.data["audiobookshelf_oidc_client_secret"]
  client_type        = "confidential"
  grant_types        = ["authorization_code", "refresh_token"]
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  signing_key        = data.authentik_certificate_key_pair.oidc_signing.id
  property_mappings = concat(
    data.authentik_property_mapping_provider_scope.oidc.ids,
    [authentik_property_mapping_provider_scope.abs_roles.id],
  )
  allowed_redirect_uris = [for u in local.contracts.oidc.audiobookshelf.redirectUris : {
    matching_mode     = "strict"
    redirect_uri_type = "authorization"
    url               = u
  }]
}

resource "authentik_provider_oauth2" "bindery" {
  name               = local.contracts.oidc.bindery.clientId
  client_id          = local.contracts.oidc.bindery.clientId
  client_secret      = data.sops_file.bindery.data["bindery_oidc_client_secret"]
  client_type        = "confidential"
  grant_types        = ["authorization_code", "refresh_token"]
  authorization_flow = data.authentik_flow.default_authorization.id
  invalidation_flow  = data.authentik_flow.default_invalidation.id
  signing_key        = data.authentik_certificate_key_pair.oidc_signing.id
  property_mappings  = data.authentik_property_mapping_provider_scope.oidc.ids
  allowed_redirect_uris = [for u in local.contracts.oidc.bindery.redirectUris : {
    matching_mode     = "strict"
    redirect_uri_type = "authorization"
    url               = u
  }]
}

resource "authentik_application" "audiobookshelf" {
  name              = "Books"
  slug              = "audiobookshelf"
  protocol_provider = authentik_provider_oauth2.audiobookshelf.id
  meta_launch_url   = "https://${local.contracts.publicHosts.books}"
}

resource "authentik_application" "bindery" {
  name              = "Book requests"
  slug              = "bindery"
  protocol_provider = authentik_provider_oauth2.bindery.id
  meta_launch_url   = "https://${local.contracts.publicHosts.bindery}"
}

locals {
  books_access = {
    audiobookshelf_users  = { app = authentik_application.audiobookshelf.uuid, group = authentik_group.book_users.id, order = 0 }
    audiobookshelf_admins = { app = authentik_application.audiobookshelf.uuid, group = authentik_group.arr_admins.id, order = 1 }
    bindery_users         = { app = authentik_application.bindery.uuid, group = authentik_group.book_users.id, order = 0 }
    bindery_admins        = { app = authentik_application.bindery.uuid, group = authentik_group.arr_admins.id, order = 1 }
  }
}

resource "authentik_policy_binding" "books_access" {
  for_each = local.books_access
  target   = each.value.app
  group    = each.value.group
  order    = each.value.order
}
