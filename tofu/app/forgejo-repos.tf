provider "forgejo" {
  host      = "https://git.minz1.com"
  api_token = var.forgejo_api_token
}

variable "forgejo_api_token" {
  description = "PAT of the Forgejo admin minz1. Set via TF_VAR_forgejo_api_token in secrets/tofu.env."
  type        = string
  sensitive   = true
}

ephemeral "sops_file" "forgejo" {
  source_file = "${path.root}/../../secrets/shared/forgejo.yaml"
}

locals {
  forgejo_repos = ["nixfiles"]
}

resource "forgejo_repository" "repo" {
  for_each = toset(local.forgejo_repos)

  # no owner: the token's own user (minz1); with owner set the provider probes orgs/admin APIs
  name           = each.key
  default_branch = "main"
  # showcase instance: these repos are public on purpose (also public on GitHub/Codeberg)
  private = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "forgejo_repository_action_secret" "attic_push_token" {
  repository_id   = forgejo_repository.repo["nixfiles"].id
  name            = "ATTIC_PUSH_TOKEN"
  data_wo         = ephemeral.sops_file.forgejo.data["attic_push_token"]
  data_wo_version = 1
}
