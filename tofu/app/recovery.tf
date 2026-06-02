resource "authentik_flow" "recovery" {
  name        = "Account Recovery"
  slug        = "account-recovery"
  designation = "recovery"
  title       = "Reset your password"
}

resource "authentik_stage_identification" "recovery" {
  name        = "recovery-identification"
  user_fields = ["email", "username"]
}

resource "authentik_stage_email" "recovery" {
  name                     = "recovery-email"
  use_global_settings      = true
  template                 = "email/password_reset.html"
  subject                  = "Reset your password"
  activate_user_on_success = true
  token_expiry             = "minutes=30"
}

resource "authentik_stage_prompt_field" "recovery_password" {
  name      = "recovery-password"
  field_key = "password"
  label     = "New Password"
  type      = "password"
  required  = true
  order     = 100
}

resource "authentik_stage_prompt_field" "recovery_password_repeat" {
  name      = "recovery-password-repeat"
  field_key = "password_repeat"
  label     = "New Password (repeat)"
  type      = "password"
  required  = true
  order     = 200
}

resource "authentik_stage_prompt" "recovery" {
  name = "recovery-prompt"
  fields = [
    authentik_stage_prompt_field.recovery_password.id,
    authentik_stage_prompt_field.recovery_password_repeat.id,
  ]
}

resource "authentik_stage_user_write" "recovery" {
  name               = "recovery-write"
  user_creation_mode = "never_create"
}

resource "authentik_stage_user_login" "recovery" {
  name = "recovery-login"
}

resource "authentik_flow_stage_binding" "recovery_identification" {
  target = authentik_flow.recovery.uuid
  stage  = authentik_stage_identification.recovery.id
  order  = 0
}

resource "authentik_flow_stage_binding" "recovery_email" {
  target = authentik_flow.recovery.uuid
  stage  = authentik_stage_email.recovery.id
  order  = 10
}

resource "authentik_flow_stage_binding" "recovery_prompt" {
  target = authentik_flow.recovery.uuid
  stage  = authentik_stage_prompt.recovery.id
  order  = 20
}

resource "authentik_flow_stage_binding" "recovery_write" {
  target = authentik_flow.recovery.uuid
  stage  = authentik_stage_user_write.recovery.id
  order  = 30
}

resource "authentik_flow_stage_binding" "recovery_login" {
  target = authentik_flow.recovery.uuid
  stage  = authentik_stage_user_login.recovery.id
  order  = 40
}
