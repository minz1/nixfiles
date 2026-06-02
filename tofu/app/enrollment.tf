data "authentik_flow" "enrollment" {
  slug = "default-source-enrollment"
}

resource "authentik_stage_invitation" "enrollment" {
  name                             = "enrollment-invitation"
  continue_flow_without_invitation = false
}

# Bind invitation stage to the SSO source enrollment flow (for federated IdP logins)
resource "authentik_flow_stage_binding" "enrollment_invitation" {
  target = data.authentik_flow.enrollment.id
  stage  = authentik_stage_invitation.enrollment.id
  order  = 0
}

# Dedicated invitation-only enrollment flow (no SSO restriction)

resource "authentik_flow" "invitation_enrollment" {
  name           = "Invitation Enrollment"
  slug           = "invitation-enrollment"
  designation    = "enrollment"
  title          = "Create your account"
  authentication = "none"
}

resource "authentik_stage_prompt_field" "inv_username" {
  name      = "inv-enrollment-username"
  field_key = "username"
  label     = "Username"
  type      = "username"
  required  = true
  order     = 100
}

resource "authentik_stage_prompt_field" "inv_email" {
  name      = "inv-enrollment-email"
  field_key = "email"
  label     = "Email"
  type      = "email"
  required  = true
  order     = 200
}

resource "authentik_stage_prompt_field" "inv_password" {
  name      = "inv-enrollment-password"
  field_key = "password"
  label     = "Password"
  type      = "password"
  required  = true
  order     = 300
}

resource "authentik_stage_prompt_field" "inv_password_repeat" {
  name      = "inv-enrollment-password-repeat"
  field_key = "password_repeat"
  label     = "Password (repeat)"
  type      = "password"
  required  = true
  order     = 400
}

resource "authentik_stage_prompt" "invitation_enrollment" {
  name = "invitation-enrollment-prompt"
  fields = [
    authentik_stage_prompt_field.inv_username.id,
    authentik_stage_prompt_field.inv_email.id,
    authentik_stage_prompt_field.inv_password.id,
    authentik_stage_prompt_field.inv_password_repeat.id,
  ]
}

resource "authentik_stage_email" "invitation_enrollment" {
  name                = "invitation-enrollment-email"
  use_global_settings = true
  template            = "email/account_confirmation.html"
  subject             = "Confirm your account"
  token_expiry        = "minutes=30"
}

resource "authentik_stage_user_write" "invitation_enrollment" {
  name                     = "invitation-enrollment-write"
  create_users_as_inactive = false
  user_creation_mode       = "always_create"
  user_type                = "internal"
}

resource "authentik_stage_user_login" "invitation_enrollment" {
  name = "invitation-enrollment-login"
}

resource "authentik_flow_stage_binding" "inv_enroll_invitation" {
  target = authentik_flow.invitation_enrollment.uuid
  stage  = authentik_stage_invitation.enrollment.id
  order  = 0
}

resource "authentik_flow_stage_binding" "inv_enroll_prompt" {
  target = authentik_flow.invitation_enrollment.uuid
  stage  = authentik_stage_prompt.invitation_enrollment.id
  order  = 10
}

resource "authentik_flow_stage_binding" "inv_enroll_email" {
  target = authentik_flow.invitation_enrollment.uuid
  stage  = authentik_stage_email.invitation_enrollment.id
  order  = 20
}

resource "authentik_flow_stage_binding" "inv_enroll_write" {
  target = authentik_flow.invitation_enrollment.uuid
  stage  = authentik_stage_user_write.invitation_enrollment.id
  order  = 30
}

resource "authentik_flow_stage_binding" "inv_enroll_login" {
  target = authentik_flow.invitation_enrollment.uuid
  stage  = authentik_stage_user_login.invitation_enrollment.id
  order  = 40
}
