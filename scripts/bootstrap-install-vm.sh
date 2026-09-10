#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
NODE="$1"
ram_dir="$(find_ram_dir)"
vm_ip=$(nix eval --raw --impure --expr "(import ${ROOT_DIR}/common/topology.nix).nodes.\"${NODE}\".networks.incus_bridge.ip")

# Built + uploaded locally, not fetched by the target — guest ACLs are default-reject, no internet.
kexec_tarball="$(nix build --no-link --print-out-paths 'github:nix-community/nixos-images#kexec-installer-nixos-unstable-noninteractive')/nixos-kexec-installer-noninteractive-x86_64-linux.tar.gz"

nix run "${ROOT_DIR}#nixos-anywhere" -- \
    --kexec "$kexec_tarball" \
    --flake "${ROOT_DIR}#${NODE}" \
    --extra-files "${ram_dir}/nixos-bootstrap-${NODE}" \
    "minz1@${vm_ip}"
rm -rf "${ram_dir}/nixos-bootstrap-${NODE}"
