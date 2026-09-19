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

# Recovery-flow MFA: without this, control of an admin's mailbox alone yields a logged-in
# admin session. deny (not configure) so a mailbox holder can't self-enrol a device here.
resource "authentik_stage_authenticator_validate" "recovery_mfa" {
  name                  = "recovery-mfa"
  not_configured_action = "deny"
  device_classes        = ["totp", "webauthn", "static"]
}

resource "authentik_policy_expression" "recovery_mfa_required" {
  name              = "recovery-mfa-required"
  execution_logging = false
  expression        = <<-EOT
    user = request.context.get("pending_user")
    return bool(user and user.pk and user.is_superuser)
  EOT
}

resource "authentik_flow_stage_binding" "recovery_mfa" {
  target               = authentik_flow.recovery.uuid
  stage                = authentik_stage_authenticator_validate.recovery_mfa.id
  order                = 15
  evaluate_on_plan     = false
  re_evaluate_policies = true
}

resource "authentik_policy_binding" "recovery_mfa" {
  policy = authentik_policy_expression.recovery_mfa_required.id
  target = authentik_flow_stage_binding.recovery_mfa.id
  order  = 0
}
