# nixfiles — command reference
# Install just: https://github.com/casey/just
# ── OpenTofu ──────────────────────────────────────────────────────────────────
# The _with-incus helper discovers the Incus host from topology at runtime,
# so adding a second incus-host node in topology.nix works automatically.

tofu-init flags="":
    @just _with-incus "sops exec-env secrets/rustfs-tofu.env 'tofu -chdir=tofu init {{ flags }}'"

# Build the bootstrap image. Produces: result/nixos.qcow2 + result/metadata.tar.xz
bootstrap-build:
    nix build .#incus-bootstrap-image -o result

# Import the bootstrap image into Incus as alias "nixos-bootstrap".

# Run this after bootstrap-build and before tofu-apply when the image has changed.
bootstrap-import:
    @just _with-incus "incus image import result/metadata.tar.xz result/nixos.qcow2 --alias nixos-bootstrap"

# Plan VMs hosted on the Incus daemon.
# Usage:
#   just tofu-plan                   # all VMs

# just tofu-plan minz-vm-nixos-0   # single VM
tofu-plan hostname="": bootstrap-build
    @just _with-incus "sops exec-env secrets/rustfs-tofu.env 'tofu -chdir=tofu plan -var=\"hostname={{ hostname }}\" -out=tofu.plan'"

tofu-apply: bootstrap-build
    @just _with-incus "sops exec-env secrets/rustfs-tofu.env 'tofu -chdir=tofu apply tofu.plan'"

tofu-destroy hostname: bootstrap-build
    @just _with-incus "sops exec-env secrets/rustfs-tofu.env 'tofu -chdir=tofu destroy -var=\"hostname={{ hostname }}\"'"

# ── Helper Orchestration (In-Memory Secrets) ──────────────────────────────────
# Stages TLS credentials for the Incus API in a tmpfs directory for the
# duration of a command, so private key material never touches disk.

[private]
_with-incus command:
    #!/usr/bin/env bash
    set -euo pipefail
    INCUS_REMOTE=$(nix eval --raw --impure \
      --expr 'let t = import ./common/topology.nix; in
              builtins.head (builtins.filter
                (name: (t.nodes.${name}.provisioner or "") == "incus-host")
                (builtins.attrNames t.nodes))')
    RAM_DIR=""
    for dir in "/run/user/$(id -u)" "/run" "/dev/shm"; do
        if [ -d "$dir" ] && [ -w "$dir" ] && [ "$(stat -f -c %T "$dir")" == "tmpfs" ]; then
            RAM_DIR="$dir"
            break
        fi
    done
    if [ -z "$RAM_DIR" ]; then
        echo "ERROR: No writable tmpfs directory found to safely stage secrets. Checked: /run/user/$(id -u), /run, /dev/shm" >&2
        echo "If you are on WSL, ensure /run/user/$(id -u) exists or use /dev/shm." >&2
        exit 1
    fi
    CONF=$(mktemp -d "$RAM_DIR/incus-tofu.XXXXXX")
    trap "rm -rf $CONF" EXIT
    cp secrets/incus-client.crt "$CONF/client.crt"
    sops -d --extract '["client_key"]' secrets/incus-client.yaml > "$CONF/client.key"
    chmod 600 "$CONF/client.key"
    INCUS_CONF="$CONF" INCUS_REMOTE="$INCUS_REMOTE" bash -c "{{ command }}"

# ── Deploy (deploy-rs) ────────────────────────────────────────────────────────
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

# ── Initial VM Provisioning (nixos-anywhere) ──────────────────────────────────
# Workflow for a new Incus VM:
#   1. just tofu-apply            (provision VM, running the bootstrap image)
#   2. just install <node>        (nixos-anywhere installs real config)
#   3. ssh-keyscan <ip> | ssh-to-age  → add age pubkey to .sops.yaml
#   4. sops secrets/<node>.yaml   (create secrets file for the host)
#   5. just deploy <node>         (all future updates via deploy-rs)

install node:
    nix run .#nixos-anywhere -- \
        --flake .#{{ node }} \
        minz1@$(nix eval --raw --impure --expr '(import ./common/topology.nix).nodes."{{ node }}".networks.incus_bridge.ip')
