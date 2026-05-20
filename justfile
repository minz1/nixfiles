# nixfiles — command reference
# Install just: https://github.com/casey/just
# ── OpenTofu ──────────────────────────────────────
# Run tofu commands against an Incus daemon.

tofu-init flags="":
    @just _with-incus "sops exec-env secrets/rustfs-tofu.env 'tofu -chdir=tofu init {{ flags }}'"

# Build the bootstrap image. Produces: result/nixos.qcow2 + result/metadata.tar.xz
bootstrap-build:
    nix build .#incus-bootstrap-image -o result

# Plan VMs hosted on a given Incus daemon.
# Usage:
#   just tofu-plan                              # all VMs on minz-home-vm-0

# just tofu-plan minz-vm-nixos-0               # single VM on minz-home-vm-0
tofu-plan hostname="": bootstrap-build
    @just _with-incus "sops exec-env secrets/rustfs-tofu.env 'tofu -chdir=tofu plan -var=\"hostname={{ hostname }}\" -out=tofu.plan'"

tofu-apply: bootstrap-build
    @just _with-incus "sops exec-env secrets/rustfs-tofu.env 'tofu -chdir=tofu apply tofu.plan'"

tofu-destroy hostname: bootstrap-build
    @just _with-incus "sops exec-env secrets/rustfs-tofu.env 'tofu -chdir=tofu destroy -var=\"hostname={{ hostname }}\"'"

# ── Helper Orchestration (In-Memory Secrets) ──────
# Orchestrates an in-memory Incus configuration directory for the duration of a command.

# This prevents sensitive PKI keys from ever touching the physical disk.
[private]
_with-incus command:
    #!/usr/bin/env bash
    set -euo pipefail
    RAM_DIR="/run/user/$(id -u)"
    if ! findmnt --target "$RAM_DIR" --types tmpfs -q 2>/dev/null; then
          echo "ERROR: $RAM_DIR is not tmpfs, refusing to stage key" >&2
          exit 1
      fi
    CONF=$(mktemp -d "$RAM_DIR/incus-tofu.XXXXXX")
    trap "rm -rf $CONF" EXIT
    cp secrets/incus-client.crt "$CONF/client.crt"
    sops -d --extract '["client_key"]' secrets/incus-client.yaml > "$CONF/client.key"
    chmod 600 "$CONF/client.key"
    INCUS_CONF="$CONF" INCUS_REMOTE=minz-home-vm-0 bash -c "{{ command }}"

# ── Deploy (deploy-rs) ────────────────────────────
# Uses deploy-rs for atomic activation and auto-rollback on failure.
# Usage: just deploy <node-name>  (e.g., just deploy minz-home-vm-0)

deploy node:
    nix run .#deploy-rs -- .#{{ node }}

deploy-all:
    nix run .#deploy-rs -- .

list-nodes:
    @nix eval --raw .#deploy.nodes --apply 'x: (builtins.concatStringsSep "\n" (builtins.attrNames x)) + "\n"'

sops-edit node:
    sops secrets/{{ node }}.yaml
