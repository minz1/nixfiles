#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
COMMAND="$1"
# must match the remote name in tofu/infra/providers.tf
INCUS_REMOTE=minz-home-nix-0
CONF=$(mktemp -d "$(find_ram_dir)/incus-tofu.XXXXXX")
trap 'rm -rf $CONF' EXIT
cp "${ROOT_DIR}/secrets/incus-client.crt" "$CONF/client.crt"
sops -d --extract '["client_key"]' "${ROOT_DIR}/secrets/incus-client.yaml" > "$CONF/client.key"
chmod 600 "$CONF/client.key"
INCUS_CONF="$CONF" INCUS_REMOTE="$INCUS_REMOTE" bash -c "$COMMAND"
