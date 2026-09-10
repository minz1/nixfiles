#!/usr/bin/env bash
# Builds toplevels for the given hosts and pushes their closures to the Attic cache. Assumes
# root in the job container (writes /etc/hosts and the system CA bundle) — true for the
# Forgejo runner's docker:// job containers. The push token is read from a file, never an
# env var or argv, via attic's token-file config form.
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

# --ignore-upstream-cache-filter: the cache's upstream-cache-key filter (cache.nixos.org-1 by
# default) skips physically storing paths it thinks are available upstream — fatal here, guests
# can't reach cache.nixos.org at all.
nix build --no-link --print-out-paths "${attrs[@]}" | attic push homelab --stdin --ignore-upstream-cache-filter
