#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
NODE="$1"
ram_dir="$(find_ram_dir)"
vm_ip=$(nix eval --raw --impure --expr "(import ${ROOT_DIR}/common/topology.nix).nodes.\"${NODE}\".networks.incus_bridge.ip")
nix run "${ROOT_DIR}#nixos-anywhere" -- \
    --flake "${ROOT_DIR}#${NODE}" \
    --extra-files "${ram_dir}/nixos-bootstrap-${NODE}" \
    "minz1@${vm_ip}"
rm -rf "${ram_dir}/nixos-bootstrap-${NODE}"
