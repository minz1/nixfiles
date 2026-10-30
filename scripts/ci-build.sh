#!/usr/bin/env bash
# Builds closures and records their paths for ci-attic-push.sh. Never sees the push token.
# Assumes root in the job container (writes /etc/hosts, CA bundle).
set -euo pipefail
repo=$(git rev-parse --show-toplevel)

hosts=("$@")
if [ "${#hosts[@]}" -eq 0 ]; then
    echo "No affected hosts; nothing to build."
    exit 0
fi

attic_host=$(fleet host attic)
attic_ip=$(fleet address "$attic_host")

if ! grep -q " ${attic_host}.internal\$" /etc/hosts; then
    echo "${attic_ip} ${attic_host}.internal" >> /etc/hosts
fi

cp "${repo}/hosts/minz-pki-0/root_ca.crt" /usr/local/share/ca-certificates/minz-pki-0-root.crt
update-ca-certificates

attrs=()
for host in "${hosts[@]}"; do
    attrs+=(".#nixosConfigurations.${host}.config.system.build.toplevel")
done

paths=$(nix build \
    --no-update-lock-file \
    --extra-substituters "https://${attic_host}.internal/homelab" \
    --extra-trusted-public-keys "homelab:/832u4B/jZREiimqBzchHGyXQZaUVKoG4TlO/nUJh10=" \
    --no-link --print-out-paths "${attrs[@]}")
echo "$paths" > "${RUNNER_TEMP:-/tmp}/attic-paths.txt"
