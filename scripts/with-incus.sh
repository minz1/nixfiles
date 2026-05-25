#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
COMMAND="$1"
INCUS_REMOTE=$(nix eval --raw --impure \
  --expr "let t = import ${ROOT_DIR}/common/topology.nix; in
          builtins.head (builtins.filter
            (name: (t.nodes.\${name}.provisioner or \"\") == \"incus-host\")
            (builtins.attrNames t.nodes))")
CONF=$(mktemp -d "$(find_ram_dir)/incus-tofu.XXXXXX")
trap 'rm -rf $CONF' EXIT
cp "${ROOT_DIR}/secrets/incus-client.crt" "$CONF/client.crt"
sops -d --extract '["client_key"]' "${ROOT_DIR}/secrets/incus-client.yaml" > "$CONF/client.key"
chmod 600 "$CONF/client.key"
INCUS_CONF="$CONF" INCUS_REMOTE="$INCUS_REMOTE" bash -c "$COMMAND"
