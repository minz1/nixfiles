#!/usr/bin/env bash
set -euo pipefail

host="${1:?usage: verify-attic-closure.sh <host>}"

# IP, not the .internal DNS name — Caddy's route match and atticd's allowed-hosts both
# accept it (hosts/minz-attic-0/configuration.nix), so this needs no DNS resolution on
# whatever machine runs it, unlike fleet NixOS hosts which get the name via extraHosts.
attic_ip=$(nix eval --raw "${ROOT_DIR}#deploy.nodes.minz-attic-0.hostname")
attic_url="https://${attic_ip}/homelab"

if nix config show substituters | grep -qF "minz-attic-0.internal"; then
    echo "refusing to run: local substituters already include the Attic cache — this check is circular" >&2
    exit 1
fi

if ! curl -fsS --max-time 5 "${attic_url}/nix-cache-info" > /dev/null; then
    echo "Attic cache unreachable at $attic_url — use SKIP_ATTIC_VERIFY=1 if that's expected" >&2
    exit 1
fi

path=$(nix build --no-link --print-out-paths "${ROOT_DIR}#nixosConfigurations.${host}.config.system.build.toplevel")

local_json=$(nix path-info --json --json-format 1 -r "$path")

mismatches=()
checked=0
while IFS= read -r p; do
    local_hash=$(echo "$local_json" | jq -r --arg p "$p" '.[$p].narHash')

    remote_json=$(nix path-info --store "$attic_url" --json --json-format 1 "$p" 2>/dev/null) || continue
    remote_hash=$(echo "$remote_json" | jq -r --arg p "$p" '.[$p].narHash // empty')
    [ -z "$remote_hash" ] && continue

    checked=$((checked + 1))
    if [ "$local_hash" != "$remote_hash" ]; then
        mismatches+=("$p (local=$local_hash remote=$remote_hash)")
    fi
done < <(echo "$local_json" | jq -r 'keys[]')

if [ "${#mismatches[@]}" -gt 0 ]; then
    echo "Attic cache mismatch for $host — possible poisoned closure:" >&2
    printf '  %s\n' "${mismatches[@]}" >&2
    exit 1
fi

total=$(echo "$local_json" | jq 'keys | length')

if [ "$checked" -eq 0 ]; then
    echo "verify-attic-closure: 0 of $total closure paths reachable on Attic — cache may be down; use SKIP_ATTIC_VERIFY=1 if that's expected" >&2
    exit 1
fi

echo "verify-attic-closure: $host OK ($checked of $total closure paths cross-checked against Attic)"
