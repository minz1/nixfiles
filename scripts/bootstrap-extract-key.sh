#!/usr/bin/env bash
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
NODE="$1"
RAM_DIR="$(find_ram_dir)"
KEY_DIR="${RAM_DIR}/nixos-bootstrap-${NODE}/persist/etc/ssh"
rm -rf "${RAM_DIR}/nixos-bootstrap-${NODE}"
mkdir -p "$KEY_DIR"
sops -d --extract '["ssh_host_ed25519_key"]' "${repo}/secrets/${NODE}.yaml" > "$KEY_DIR/ssh_host_ed25519_key"
chmod 600 "$KEY_DIR/ssh_host_ed25519_key"
ssh-keygen -y -f "$KEY_DIR/ssh_host_ed25519_key" > "$KEY_DIR/ssh_host_ed25519_key.pub"
