#!/usr/bin/env bash
set -euo pipefail
COMMAND="$1"
INCUS_REMOTE=$(nix eval --raw --impure \
  --expr 'let t = import ./common/topology.nix; in
          builtins.head (builtins.filter
            (name: (t.nodes.${name}.provisioner or "") == "incus-host")
            (builtins.attrNames t.nodes))')
RAM_DIR=""
for dir in "/run/user/$(id -u)" "/run" "/dev/shm"; do
    if [ -d "$dir" ] && [ -w "$dir" ] && [ "$(stat -f -c %T "$dir")" == "tmpfs" ]; then
        RAM_DIR="$dir"
        break
    fi
done
if [ -z "$RAM_DIR" ]; then
    echo "ERROR: No writable tmpfs directory found to safely stage secrets. Checked: /run/user/$(id -u), /run, /dev/shm" >&2
    echo "If you are on WSL, ensure /run/user/$(id -u) exists or use /dev/shm." >&2
    exit 1
fi
CONF=$(mktemp -d "$RAM_DIR/incus-tofu.XXXXXX")
trap "rm -rf $CONF" EXIT
cp secrets/incus-client.crt "$CONF/client.crt"
sops -d --extract '["client_key"]' secrets/incus-client.yaml > "$CONF/client.key"
chmod 600 "$CONF/client.key"
INCUS_CONF="$CONF" INCUS_REMOTE="$INCUS_REMOTE" bash -c "$COMMAND"
