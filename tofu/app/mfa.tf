data "authentik_stage" "totp_setup" {
  name = "default-authenticator-totp-setup"
}

data "authentik_stage" "webauthn_setup" {
  name = "default-authenticator-webauthn-setup"
}

data "authentik_stage" "static_setup" {
  name = "default-authenticator-static-setup"
}

resource "authentik_stage_authenticator_validate" "admin_mfa_enforce" {
  name                  = "admin-mfa-enforce"
  not_configured_action = "configure"
  device_classes        = ["totp", "webauthn"]
  configuration_stages  = [data.authentik_stage.totp_setup.id, data.authentik_stage.webauthn_setup.id]
}

resource "authentik_policy_expression" "admin_mfa_required" {
  name              = "admin-mfa-required"
  execution_logging = false
  expression        = <<-EOT
    user = request.context.get("pending_user")
    if not user or not user.pk or not user.is_superuser:
        return False
    return not (ak_user_has_authenticator(user, "totp") or ak_user_has_authenticator(user, "webauthn"))
  EOT
}

resource "authentik_flow_stage_binding" "admin_mfa_enforce" {
  target               = data.authentik_flow.default_authentication.id
  stage                = authentik_stage_authenticator_validate.admin_mfa_enforce.id
  order                = 35
  evaluate_on_plan     = false
  re_evaluate_policies = true
}

resource "authentik_policy_binding" "admin_mfa_enforce" {
  policy = authentik_policy_expression.admin_mfa_required.id
  target = authentik_flow_stage_binding.admin_mfa_enforce.id
  order  = 0
}

resource "authentik_policy_expression" "admin_static_required" {
  name              = "admin-static-required"
  execution_logging = false
  expression        = <<-EOT
    user = request.context.get("pending_user")
    if not user or not user.pk or not user.is_superuser:
        return False
    return not ak_user_has_authenticator(user, "static")
  EOT
}

resource "authentik_flow_stage_binding" "admin_static_setup" {
  target               = data.authentik_flow.default_authentication.id
  stage                = data.authentik_stage.static_setup.id
  order                = 40
  evaluate_on_plan     = false
  re_evaluate_policies = true
}

resource "authentik_policy_binding" "admin_static_setup" {
  policy = authentik_policy_expression.admin_static_required.id
  target = authentik_flow_stage_binding.admin_static_setup.id
  order  = 0
}
