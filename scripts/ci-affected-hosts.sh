#!/usr/bin/env bash
# Affected hosts for $1..$2 (default HEAD). Includes every deployable host — vultr-nix-0 still
# needs building/caching even though CI never deploys anything.
set -euo pipefail

before="${1:-}"
after="${2:-HEAD}"

all=$(just deploy list | xargs)

# also falls back to the full fleet when $before isn't a commit this checkout knows about
# (e.g. a workflow's first-ever run, before a range against it is even meaningful)
if [ -z "$before" ] || [ "$before" = "0000000000000000000000000000000000000000" ] \
    || ! git -C "${ROOT_DIR}" cat-file -e "${before}^{commit}" 2>/dev/null; then
    echo "$all"
    exit 0
fi

changed=$(git -C "${ROOT_DIR}" log --name-only --pretty=format: "${before}..${after}" | { grep -v '^$' || true; } | sort -u)

if echo "$changed" | grep -qE '^(modules/|common/|pkgs/|config/|hosts/minz-pki-0/root_ca\.crt|flake\.(nix|lock))'; then
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
