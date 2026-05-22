#!/usr/bin/env bash
set -euo pipefail
NODE="$1"
KEY_DIR="/dev/shm/nixos-bootstrap-${NODE}/persist/etc/ssh"
rm -rf "/dev/shm/nixos-bootstrap-${NODE}"
mkdir -p "$KEY_DIR"
sops -d --extract '["ssh_host_ed25519_key"]' "secrets/${NODE}.yaml" > "$KEY_DIR/ssh_host_ed25519_key"
chmod 600 "$KEY_DIR/ssh_host_ed25519_key"
ssh-keygen -y -f "$KEY_DIR/ssh_host_ed25519_key" > "$KEY_DIR/ssh_host_ed25519_key.pub"
