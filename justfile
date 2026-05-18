# nixfiles — command reference
# Install just: https://github.com/casey/just
# ── OpenTofu ──────────────────────────────────────
# Run tofu commands against an Incus daemon.
# Credentials for the RustFS S3 backend are passed via sops exec-env.
# The secret file must contain:
#   AWS_ACCESS_KEY_ID=<value>
#   AWS_SECRET_ACCESS_KEY=<value>

tofu-init:
    [ -d tofu/.terraform ] || (sops exec-env secrets/rustfs-tofu.env "tofu -chdir=tofu init")

# Decrypt the Incus TLS client certs into tofu/.incus/
# Requires secrets/incus-client.yaml with key client_key.

# The cert (client.crt) is in secrets/incus-client.crt — it's public.
tofu-setup-certs:
    mkdir -p tofu/.incus
    cp secrets/incus-client.crt tofu/.incus/client.crt
    sops -d --extract '["client_key"]' secrets/incus-client.yaml > tofu/.incus/client.key
    chmod 600 tofu/.incus/client.key

# Plan VMs hosted on a given Incus daemon.
# Usage:
#   just tofu-plan                              # all VMs on minz-home-vm-0

# just tofu-plan minz-vm-nixos-0               # single VM on minz-home-vm-0
tofu-plan hostname="": tofu-init tofu-setup-certs
    INCUS_CONF=$PWD/tofu/.incus INCUS_REMOTE=minz-home-vm-0 sops exec-env secrets/rustfs-tofu.env \
        "tofu -chdir=tofu plan -var=\"hostname={{ hostname }}\" -out=tofu.plan"

tofu-apply hostname="": tofu-init tofu-setup-certs
    INCUS_CONF=$PWD/tofu/.incus INCUS_REMOTE=minz-home-vm-0 sops exec-env secrets/rustfs-tofu.env \
        "tofu -chdir=tofu apply tofu.plan"

tofu-destroy hostname: tofu-init tofu-setup-certs
    INCUS_CONF=$PWD/tofu/.incus INCUS_REMOTE=minz-home-vm-0 sops exec-env secrets/rustfs-tofu.env \
        "tofu -chdir=tofu destroy -var=\"hostname={{ hostname }}\""

sops-edit node:
    sops secrets/{{ node }}.yaml

# ── Deploy (deploy-rs) ────────────────────────────
# Uses deploy-rs for atomic activation and auto-rollback on failure.
# Usage: just deploy <node-name>  (e.g., just deploy minz-home-vm-0)

deploy node:
    nix run .#deploy-rs -- .#{{ node }}

deploy-all:
    nix run .#deploy-rs -- .

list-nodes:
    @nix eval --raw .#deploy.nodes --apply 'x: (builtins.concatStringsSep "\n" (builtins.attrNames x)) + "\n"'
