variable "ldap_bind_password" {
  description = "Password for the Authentik LDAP bind service account (jellyfin-ldap-bind). Set via TF_VAR_ldap_bind_password in secrets/tofu.env."
  type        = string
  sensitive   = true
}

variable "seerr_smtp_password" {
  description = "SMTP password for Seerr email notifications (Resend API key). Set via TF_VAR_seerr_smtp_password in secrets/tofu.env."
  type        = string
  sensitive   = true
}

variable "seerr_discord_webhook" {
  description = "Discord webhook URL for Seerr notifications. Set via TF_VAR_seerr_discord_webhook in secrets/tofu.env."
  type        = string
  sensitive   = true
}
