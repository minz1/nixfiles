#!/usr/bin/env bash
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
NODE="$1"
ram_dir="$(find_ram_dir)"
vm_ip=$(fleet address "$NODE")

# Built + uploaded locally, not fetched by the target — guest ACLs are default-reject, no internet.
kexec_tarball="$(nix build --no-link --print-out-paths "${repo}#kexec-installer")/nixos-kexec-installer-noninteractive-x86_64-linux.tar.gz"

nixos-anywhere \
    --kexec "$kexec_tarball" \
    --flake "${repo}#${NODE}" \
    --extra-files "${ram_dir}/nixos-bootstrap-${NODE}" \
    "minz1@${vm_ip}"
rm -rf "${ram_dir}/nixos-bootstrap-${NODE}"
