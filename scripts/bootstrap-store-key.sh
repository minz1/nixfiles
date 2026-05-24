#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
NODE="$1"
KEY_FILE="$(find_ram_dir)/nixos-bootstrap-${NODE}/persist/etc/ssh/ssh_host_ed25519_key"
if [ ! -f "$KEY_FILE" ]; then
    echo "ERROR: Run 'just bootstrap keygen ${NODE}' first." >&2
    exit 1
fi
sops --set '["ssh_host_ed25519_key"] '"$(jq -Rs . < "$KEY_FILE")" "${ROOT_DIR}/secrets/${NODE}.yaml"
echo "Stored in ${ROOT_DIR}/secrets/${NODE}.yaml — commit and push before running bootstrap install."
