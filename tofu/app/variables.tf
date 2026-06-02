variable "ldap_bind_password" {
  description = "Password for the Authentik LDAP bind service account (jellyfin-ldap-bind). Set via TF_VAR_ldap_bind_password in secrets/tofu.env."
  type        = string
  sensitive   = true
}
