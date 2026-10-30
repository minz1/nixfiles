#!/usr/bin/env bash
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
NODE="$1"
IP="$2"
ram_dir="$(find_ram_dir)"
nixos-anywhere \
    --flake "${repo}#${NODE}" \
    --extra-files "${ram_dir}/nixos-bootstrap-${NODE}" \
    --generate-hardware-config nixos-generate-config "${repo}/hosts/${NODE}/hardware-configuration.nix" \
    "root@${IP}"
rm -rf "${ram_dir}/nixos-bootstrap-${NODE}"
