# Minecraft account-linking flow: users run "Link Minecraft Account" in the Authentik self-service panel; game-0's whitelist sync polls for minecraft_uuid and writes whitelist.json.

resource "authentik_group" "minecraft_players" {
  name = "minecraft-players"
}

# Prompt: collect the Minecraft username.
resource "authentik_stage_prompt_field" "minecraft_username" {
  name        = "minecraft_username"
  field_key   = "attributes.minecraft_username"
  type        = "text"
  label       = "Minecraft Username"
  placeholder = "YourExactUsername"
  required    = true
  order       = 0
}

resource "authentik_stage_prompt" "minecraft_register" {
  name                = "minecraft-register-prompt"
  fields              = [authentik_stage_prompt_field.minecraft_username.id]
  validation_policies = [authentik_policy_expression.minecraft_uuid_lookup.id]
}

# User write stage: persist minecraft_uuid and minecraft_username as user attributes.
resource "authentik_stage_user_write" "minecraft_write" {
  name               = "minecraft-user-write"
  user_creation_mode = "never_create"
}

resource "authentik_flow" "minecraft_registration" {
  name               = "minecraft-registration"
  slug               = "minecraft-registration"
  title              = "Link Minecraft Account"
  designation        = "stage_configuration"
  policy_engine_mode = "all"
}

resource "authentik_flow_stage_binding" "minecraft_prompt" {
  target = authentik_flow.minecraft_registration.uuid
  stage  = authentik_stage_prompt.minecraft_register.id
  order  = 10
}

resource "authentik_flow_stage_binding" "minecraft_write" {
  target = authentik_flow.minecraft_registration.uuid
  stage  = authentik_stage_user_write.minecraft_write.id
  order  = 20
}

# Expression policy: validates the username against the Mojang API and injects the UUID into prompt_data before user_write persists it.
resource "authentik_policy_expression" "minecraft_uuid_lookup" {
  name              = "minecraft-uuid-lookup"
  execution_logging = true
  expression = file("${path.module}/policies/minecraft-uuid-lookup.py")
}

# Application entry so the flow appears in the user panel.
resource "authentik_application" "minecraft_registration" {
  name            = "Link Minecraft Account"
  slug            = "minecraft-registration"
  meta_launch_url = "https://auth.minz1.com/if/flow/minecraft-registration/"
  open_in_new_tab = false
}

# ── Whitelist sync service account ───────────────────────────────────────────

resource "authentik_user" "minecraft_sync" {
  username = "minecraft-whitelist-sync"
  name     = "Minecraft Whitelist Sync"
  type     = "service_account"
}

resource "authentik_group" "minecraft_sync" {
  name         = "minecraft-sync"
  is_superuser = true
  users        = [tonumber(authentik_user.minecraft_sync.id)]
}

resource "authentik_token" "minecraft_sync" {
  identifier   = "minecraft-whitelist-sync"
  user         = tonumber(authentik_user.minecraft_sync.id)
  intent       = "api"
  description  = "Whitelist sync — read-only access to list internal users"
  expiring     = false
  retrieve_key = true
}

output "minecraft_sync_token" {
  value     = authentik_token.minecraft_sync.key
  sensitive = true
}
