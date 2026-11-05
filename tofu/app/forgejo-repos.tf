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
  # repos are filled by pushing; the provider's default auto_init adds a README commit that blocks the first push
  auto_init = false

  lifecycle {
    prevent_destroy = true
    # auto_init forces replacement; nixfiles was created with the default before it was set
    ignore_changes = [auto_init]
  }
}

resource "forgejo_repository_action_secret" "attic_push_token" {
  repository_id = forgejo_repository.repo["nixfiles"].id
  name          = "ATTIC_PUSH_TOKEN"
  data_wo       = ephemeral.sops_file.forgejo.data["attic_push_token"]
  # bump whenever attic_push_token is rotated in sops; write-only values aren't diffed
  data_wo_version = 2
}
