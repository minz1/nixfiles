set tempdir := "/tmp"

flake := justfile_directory()

# Deploy one host: build it, check Attic, deploy with retry, wait until reachable.
node host:
    nix run {{ flake }}#deploy-phased -- "{{ host }}"

# List all nodes defined in the flake.
list:
    @nix run {{ flake }}#fleet-cli -- hosts

# Print dependency-ordered deploy phases, one per line, hosts space-separated.
[private]
_phases:
    @nix run {{ flake }}#fleet-cli -- phases

# Deploy nodes in dependency order
phased *hosts:
    nix run {{ flake }}#deploy-phased -- {{ hosts }}

# Cross-check hosts' toplevel closures against Attic for a poisoned cache entry. Defaults to every deployed node.
verify-cache *hosts:
    #!/usr/bin/env bash
    set -uo pipefail
    failed=()
    for host in {{ if hosts == "" { "$(just deploy list)" } else { hosts } }}; do
      nix run {{ flake }}#verify-attic-closure -- "$host" || failed+=("$host")
    done
    if [ "${#failed[@]}" -gt 0 ]; then
      echo "Failed: ${failed[*]}" >&2
      exit 1
    fi

all:
    just deploy phased
