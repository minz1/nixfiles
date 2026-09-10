#!/usr/bin/env bash
# Builds + pushes closures to Attic. Assumes root in the job container (writes /etc/hosts, CA bundle).
set -euo pipefail

hosts=("$@")
if [ "${#hosts[@]}" -eq 0 ]; then
    echo "No affected hosts; nothing to build or push."
    exit 0
fi

attic_ip=$(TOPO="${ROOT_DIR}/common/topology.nix" nix eval --raw --impure --expr '
  let t = import (builtins.getEnv "TOPO");
  in t.nodes."minz-attic-0".networks.incus_bridge.ip')

if ! grep -q ' minz-attic-0.internal$' /etc/hosts; then
    echo "${attic_ip} minz-attic-0.internal" >> /etc/hosts
fi

cp "${ROOT_DIR}/hosts/minz-pki-0/root_ca.crt" /usr/local/share/ca-certificates/minz-pki-0-root.crt
update-ca-certificates

config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/attic"
mkdir -p "$config_dir"
cat > "${config_dir}/config.toml" <<EOF
default-server = "homelab"

[servers.homelab]
endpoint = "https://minz-attic-0.internal/"
token-file = "/run/secrets/attic_push_token"
EOF
chmod 600 "${config_dir}/config.toml"

attrs=()
for host in "${hosts[@]}"; do
    attrs+=(".#nixosConfigurations.${host}.config.system.build.toplevel")
done

# --ignore-upstream-cache-filter: Attic skips storing paths it thinks are on cache.nixos.org — fatal, guests can't reach it.
nix build --no-link --print-out-paths "${attrs[@]}" | attic push homelab --stdin --ignore-upstream-cache-filter
