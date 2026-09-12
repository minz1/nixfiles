set tempdir := "/tmp"

# Deploy a single node with auto-rollback on failure.
node host:
    nix run ${ROOT_DIR}#deploy-rs -- ${ROOT_DIR}#{{ host }}

# List all nodes defined in the flake.
list:
    @nix eval --raw ${ROOT_DIR}#deploy.nodes --apply 'x: (builtins.concatStringsSep "\n" (builtins.attrNames x)) + "\n"'

# Print dependency-ordered deploy phases, one per line, hosts space-separated.
[private]
_phases:
    @nix eval --raw ${ROOT_DIR}#deployPhases --apply 'phases: builtins.concatStringsSep "\n" (map (hosts: builtins.concatStringsSep " " hosts) phases)'

[private]
_deploy-retry host attempts="3":
    ${ROOT_DIR}/scripts/deploy-retry.sh "{{ host }}" "{{ attempts }}"

[private]
_wait-healthy host timeout="120":
    ${ROOT_DIR}/scripts/deploy-wait-healthy.sh "{{ host }}" "{{ timeout }}"

# Deploy nodes in dependency order
phased *hosts:
    ${ROOT_DIR}/scripts/deploy-phased.sh {{ hosts }}

# Cross-check hosts' toplevel closures against Attic for a poisoned cache entry. Defaults to every deployed node.
verify-cache *hosts:
    #!/usr/bin/env bash
    set -uo pipefail
    failed=()
    for host in {{ if hosts == "" { "$(just deploy list)" } else { hosts } }}; do
      ${ROOT_DIR}/scripts/verify-attic-closure.sh "$host" || failed+=("$host")
    done
    if [ "${#failed[@]}" -gt 0 ]; then
      echo "Failed: ${failed[*]}" >&2
      exit 1
    fi

all:
    just deploy phased
