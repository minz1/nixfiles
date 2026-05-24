#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
NODE="$1"
RAM_DIR="$(find_ram_dir)"
KEY_DIR="${RAM_DIR}/nixos-bootstrap-${NODE}/persist/etc/ssh"
rm -rf "${RAM_DIR}/nixos-bootstrap-${NODE}"
mkdir -p "$KEY_DIR"
ssh-keygen -t ed25519 -q -N "" -f "$KEY_DIR/ssh_host_ed25519_key"
chmod 600 "$KEY_DIR/ssh_host_ed25519_key"
echo "Age pubkey for ${NODE}:"
ssh-to-age < "$KEY_DIR/ssh_host_ed25519_key.pub"
