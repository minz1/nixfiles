#!/usr/bin/env bash
# Pushes the paths ci-build.sh recorded. Runs as its own CI step so no build process shares an environment with the token.
set -euo pipefail

: "${ATTIC_PUSH_TOKEN:?ATTIC_PUSH_TOKEN not set}"
paths_file="${RUNNER_TEMP:-/tmp}/attic-paths.txt"

config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/attic"
mkdir -p "$config_dir"
umask 077
printf '%s' "$ATTIC_PUSH_TOKEN" > "${config_dir}/token"
cat > "${config_dir}/config.toml" <<CONF
default-server = "homelab"

[servers.homelab]
endpoint = "https://minz-attic-0.internal/"
token-file = "${config_dir}/token"
CONF

# --ignore-upstream-cache-filter: Attic skips storing paths it thinks are on cache.nixos.org — fatal, guests can't reach it.
nix shell nixpkgs#attic-client --command attic push homelab --stdin --ignore-upstream-cache-filter < "$paths_file"
