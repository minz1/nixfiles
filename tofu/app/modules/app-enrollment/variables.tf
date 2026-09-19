variable "app_name" {
  description = "Application name — used as prefix for all resource names and flow slugs."
  type        = string
}

variable "group_id" {
  description = "Authentik group ID to add users to on enrollment and join. Omit for generic account creation with no group."
  type        = string
  default     = null
}
