#!/usr/bin/env bash
set -euo pipefail
NODE="$1"
KEY_DIR="/dev/shm/nixos-bootstrap-${NODE}/persist/etc/ssh"
rm -rf "/dev/shm/nixos-bootstrap-${NODE}"
mkdir -p "$KEY_DIR"
ssh-keygen -t ed25519 -q -N "" -f "$KEY_DIR/ssh_host_ed25519_key"
chmod 600 "$KEY_DIR/ssh_host_ed25519_key"
echo "Age pubkey for ${NODE}:"
ssh-to-age < "$KEY_DIR/ssh_host_ed25519_key.pub"
