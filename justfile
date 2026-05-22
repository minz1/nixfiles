mod bootstrap "just/bootstrap.just"
mod deploy "just/deploy.just"
mod tofu "just/tofu.just"

sops-edit node:
    sops secrets/{{ node }}.yaml
