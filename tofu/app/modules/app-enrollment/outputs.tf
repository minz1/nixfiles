output "enrollment_flow_slug" {
  description = "Slug of the enrollment flow. Invitation URL: https://auth.minz1.com/if/flow/<slug>/"
  value       = authentik_flow.enrollment.slug
}

output "enrollment_invitation_stage_id" {
  description = "ID of the enrollment invitation stage, for binding to additional flows if needed."
  value       = authentik_stage_invitation.enrollment.id
}

output "join_flow_slug" {
  description = "Slug of the join flow for existing users. URL: https://auth.minz1.com/if/flow/<slug>/"
  value       = authentik_flow.join.slug
}

output "join_invitation_stage_id" {
  description = "ID of the join invitation stage."
  value       = authentik_stage_invitation.join.id
}
