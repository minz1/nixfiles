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

variable "jellyfin_api_key" { sensitive = true }

# The checked fleet data (`nix eval --json .#fleet`); `just tofu app-plan` sets TF_VAR_fleet.
variable "fleet" {
  type = any
}

locals {
  authentik_url = "https://${var.fleet.addresses[var.fleet.services.authentik.host]}:${var.fleet.services.authentik.port}"
  media_caddy   = var.fleet.services["media-caddy"]
  media_ip      = var.fleet.addresses[local.media_caddy.host]
  media_url     = "https://${local.media_ip}:${local.media_caddy.port}"
}
