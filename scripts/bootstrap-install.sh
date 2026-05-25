#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
NODE="$1"
IP="$2"
ram_dir="$(find_ram_dir)"
nix run "${ROOT_DIR}#nixos-anywhere" -- \
    --flake "${ROOT_DIR}#${NODE}" \
    --extra-files "${ram_dir}/nixos-bootstrap-${NODE}" \
    --generate-hardware-config nixos-generate-config "${ROOT_DIR}/hosts/${NODE}/hardware-configuration.nix" \
    "root@${IP}"
rm -rf "${ram_dir}/nixos-bootstrap-${NODE}"
