# nixfiles — command reference
# Install just: https://github.com/casey/just
# ── OpenTofu ──────────────────────────────────────
# Run tofu commands against the home VM's Incus daemon.
# Requires the Incus remote to be configured:
#   incus remote add home-vm 10.8.0.5:8443

tofu-init:
    [ -d tofu/.terraform ] || (cd tofu && tofu init)

tofu-plan: tofu-init
    cd tofu && INCUS_REMOTE=home-vm tofu plan

tofu-apply: tofu-init
    cd tofu && INCUS_REMOTE=home-vm tofu apply

# ── Deploy (deploy-rs) ────────────────────────────
# Uses deploy-rs for atomic activation and auto-rollback on failure.
# Usage: just deploy <node-name>  (e.g., just deploy minz-home-vm-0)

deploy node:
    nix run .#deploy-rs -- .#{{ node }}

deploy-all:
    nix run .#deploy-rs -- .

list-nodes:
    @nix eval --raw .#deploy.nodes --apply 'x: (builtins.concatStringsSep "\n" (builtins.attrNames x)) + "\n"'
