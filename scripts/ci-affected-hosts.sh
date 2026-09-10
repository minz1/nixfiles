#!/usr/bin/env bash
# Prints the space-separated list of NixOS hosts whose closure needs building for commits
# between $1 (before-sha) and $2 (after-sha, default HEAD). An empty/all-zero $1 (first push
# to a ref) or a change touching modules/common/flake.* triggers a full-fleet rebuild. Unlike
# deploy.yaml's old version of this logic, ci_managed is not honored here — vultr-nix-0's
# closure still needs building and caching even though CI never deploys to it directly.
set -euo pipefail

before="${1:-}"
after="${2:-HEAD}"

# single-quoted: this is a Nix expression, not a bash interpolation target
# shellcheck disable=SC2016
all=$(TOPO="${ROOT_DIR}/common/topology.nix" nix eval --raw --impure --expr '
  let
    t = import (builtins.getEnv "TOPO");
    names = builtins.filter (
      name:
      let
        n = t.nodes.${name};
      in
      (n.os or "") == "nixos"
      && (if (n.provisioner or "") == "incus" then n.deployed or false else true)
    ) (builtins.attrNames t.nodes);
  in
  builtins.concatStringsSep " " names')

if [ -z "$before" ] || [ "$before" = "0000000000000000000000000000000000000000" ]; then
    echo "$all"
    exit 0
fi

changed=$(git -C "${ROOT_DIR}" log --name-only --pretty=format: "${before}..${after}" | grep -v '^$' | sort -u)

if echo "$changed" | grep -qE '^(modules/|common/|flake\.(nix|lock))'; then
    echo "$all"
    exit 0
fi

hosts=""
for host in $all; do
    if echo "$changed" | grep -q "^hosts/$host/"; then
        hosts="$hosts $host"
    fi
done
echo "${hosts# }"
