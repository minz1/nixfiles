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
#   just tofu-plan minz-vm-nixos-0   # single VM
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
    ./scripts/with-incus.sh "{{ command }}"

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

# ── Initial Host Provisioning (nixos-anywhere) ────────────────────────────────
# All hosts — VMs and bare-metal alike — have their SSH host key generated once,
# stored in sops, and reused on every reprovisioning. Rotation is rare and
# follows the same procedure everywhere: bootstrap-keygen → update .sops.yaml →
# bootstrap-store-key → bootstrap-install[-vm].
#
# First provisioning of any host:
#   1. just bootstrap-keygen <node>                  (generates key in RAM, prints age pubkey)
#   2. Add age pubkey to .sops.yaml; sops updatekeys secrets/<node>.yaml
#   3. just bootstrap-store-key <node>               (writes private key into sops)
#   4. git commit -am "sops: register <node>"; git push
#   5. just bootstrap-install-vm <node>              (Incus VM — IP from topology)
#      just bootstrap-install <node> <ip>            (bare-metal / cloud — also writes hosts/<node>/hardware-configuration.nix)
#   6. just deploy <node>
#
# Reprovisioning (key unchanged, no .sops.yaml update needed):
#   just bootstrap-install[-vm] <node> [<ip>]
#   just deploy <node>

bootstrap-keygen node:
    ./scripts/bootstrap-keygen.sh "{{ node }}"

bootstrap-store-key node:
    ./scripts/bootstrap-store-key.sh "{{ node }}"

[private]
_bootstrap-extract-key node:
    ./scripts/bootstrap-extract-key.sh "{{ node }}"

bootstrap-install node ip: (_bootstrap-extract-key node)
    nix run .#nixos-anywhere -- \
        --flake .#{{ node }} \
        --extra-files /dev/shm/nixos-bootstrap-{{ node }} \
        --generate-hardware-config nixos-generate-config hosts/{{ node }}/hardware-configuration.nix \
        root@{{ ip }}
    rm -rf /dev/shm/nixos-bootstrap-{{ node }}

bootstrap-install-vm node: (_bootstrap-extract-key node)
    nix run .#nixos-anywhere -- \
        --flake .#{{ node }} \
        --extra-files /dev/shm/nixos-bootstrap-{{ node }} \
        minz1@$(nix eval --raw --impure --expr '(import ./common/topology.nix).nodes."{{ node }}".networks.incus_bridge.ip')
    rm -rf /dev/shm/nixos-bootstrap-{{ node }}
