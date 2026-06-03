data "authentik_source" "inbuilt" {
  managed = "goauthentik.io/sources/inbuilt"
}

resource "authentik_stage_invitation" "enrollment" {
  name                             = "${var.app_name}-enrollment-invitation"
  continue_flow_without_invitation = false
}

resource "authentik_stage_prompt_field" "username" {
  name      = "${var.app_name}-enroll-username"
  field_key = "username"
  label     = "Username"
  type      = "username"
  required  = true
  order     = 100
}

resource "authentik_stage_prompt_field" "display_name" {
  name      = "${var.app_name}-enroll-display-name"
  field_key = "name"
  label     = "Display Name (optional)"
  type      = "text"
  required  = false
  order     = 150
}

resource "authentik_stage_prompt_field" "email" {
  name      = "${var.app_name}-enroll-email"
  field_key = "email"
  label     = "Email"
  type      = "email"
  required  = true
  order     = 200
}

resource "authentik_stage_prompt_field" "password" {
  name      = "${var.app_name}-enroll-password"
  field_key = "password"
  label     = "Password"
  type      = "password"
  required  = true
  order     = 300
}

resource "authentik_stage_prompt_field" "password_repeat" {
  name      = "${var.app_name}-enroll-password-repeat"
  field_key = "password_repeat"
  label     = "Password (repeat)"
  type      = "password"
  required  = true
  order     = 400
}

resource "authentik_stage_prompt" "enrollment" {
  name = "${var.app_name}-enrollment-prompt"
  fields = [
    authentik_stage_prompt_field.username.id,
    authentik_stage_prompt_field.display_name.id,
    authentik_stage_prompt_field.email.id,
    authentik_stage_prompt_field.password.id,
    authentik_stage_prompt_field.password_repeat.id,
  ]
}

resource "authentik_stage_email" "enrollment" {
  name                = "${var.app_name}-enrollment-email"
  use_global_settings = true
  template            = "email/account_confirmation.html"
  subject             = "Confirm your account"
  token_expiry        = "minutes=30"
}

resource "authentik_stage_user_write" "enrollment" {
  name                     = "${var.app_name}-enrollment-write"
  create_users_as_inactive = false
  user_creation_mode       = "always_create"
  user_type                = "internal"
  create_users_group       = var.group_id
}

resource "authentik_stage_user_login" "enrollment" {
  name = "${var.app_name}-enrollment-login"
}

resource "authentik_flow" "enrollment" {
  name           = "${var.app_name}-enrollment"
  slug           = "${var.app_name}-enrollment"
  designation    = "enrollment"
  title          = "Create your account"
  authentication = "none"
}

resource "authentik_flow_stage_binding" "enroll_invitation" {
  target = authentik_flow.enrollment.uuid
  stage  = authentik_stage_invitation.enrollment.id
  order  = 0
}

resource "authentik_flow_stage_binding" "enroll_prompt" {
  target = authentik_flow.enrollment.uuid
  stage  = authentik_stage_prompt.enrollment.id
  order  = 10
}

resource "authentik_flow_stage_binding" "enroll_write" {
  target = authentik_flow.enrollment.uuid
  stage  = authentik_stage_user_write.enrollment.id
  order  = 20
}

resource "authentik_flow_stage_binding" "enroll_email" {
  target = authentik_flow.enrollment.uuid
  stage  = authentik_stage_email.enrollment.id
  order  = 30
}

resource "authentik_flow_stage_binding" "enroll_login" {
  target = authentik_flow.enrollment.uuid
  stage  = authentik_stage_user_login.enrollment.id
  order  = 40
}

resource "authentik_stage_invitation" "join" {
  name                             = "${var.app_name}-join-invitation"
  continue_flow_without_invitation = !var.join_require_invitation
}

resource "authentik_stage_password" "join" {
  name     = "${var.app_name}-join-password"
  backends = ["authentik.core.auth.InbuiltBackend"]
}

resource "authentik_stage_identification" "join" {
  name           = "${var.app_name}-join-identification"
  user_fields    = ["username", "email"]
  sources        = [data.authentik_source.inbuilt.uuid]
  password_stage = authentik_stage_password.join.id
}

resource "authentik_stage_user_write" "join" {
  name               = "${var.app_name}-join-write"
  user_creation_mode = "never_create"
  create_users_group = var.group_id
}

resource "authentik_stage_user_login" "join" {
  name = "${var.app_name}-join-login"
}

resource "authentik_flow" "join" {
  name           = "${var.app_name}-join"
  slug           = "${var.app_name}-join"
  designation    = "enrollment"
  title          = "Join ${var.app_name}"
  authentication = "none"
}

resource "authentik_flow_stage_binding" "join_invitation" {
  target = authentik_flow.join.uuid
  stage  = authentik_stage_invitation.join.id
  order  = 0
}

resource "authentik_flow_stage_binding" "join_identification" {
  target = authentik_flow.join.uuid
  stage  = authentik_stage_identification.join.id
  order  = 10
}

resource "authentik_flow_stage_binding" "join_write" {
  target = authentik_flow.join.uuid
  stage  = authentik_stage_user_write.join.id
  order  = 20
}

resource "authentik_flow_stage_binding" "join_login" {
  target = authentik_flow.join.uuid
  stage  = authentik_stage_user_login.join.id
  order  = 30
}
