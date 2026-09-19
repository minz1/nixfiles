#!/usr/bin/env bash
# Builds closures and records their paths for ci-attic-push.sh. Never sees the push token.
# Assumes root in the job container (writes /etc/hosts, CA bundle).
set -euo pipefail

hosts=("$@")
if [ "${#hosts[@]}" -eq 0 ]; then
    echo "No affected hosts; nothing to build."
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

attrs=()
for host in "${hosts[@]}"; do
    attrs+=(".#nixosConfigurations.${host}.config.system.build.toplevel")
done

paths=$(nix build \
    --no-update-lock-file \
    --extra-substituters https://minz-attic-0.internal/homelab \
    --extra-trusted-public-keys "homelab:/832u4B/jZREiimqBzchHGyXQZaUVKoG4TlO/nUJh10=" \
    --no-link --print-out-paths "${attrs[@]}")
echo "$paths" > "${RUNNER_TEMP:-/tmp}/attic-paths.txt"
