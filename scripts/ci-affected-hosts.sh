#!/usr/bin/env bash
# Affected hosts for $1..$2 (default HEAD). Unlike deploy.yaml's old logic, ci_managed is not
# honored — vultr-nix-0 still needs building/caching even though CI never deploys to it.
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

# also falls back to the full fleet when $before isn't a commit this checkout knows about
# (e.g. a workflow's first-ever run, before a range against it is even meaningful)
if [ -z "$before" ] || [ "$before" = "0000000000000000000000000000000000000000" ] \
    || ! git -C "${ROOT_DIR}" cat-file -e "${before}^{commit}" 2>/dev/null; then
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
