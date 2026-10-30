#!/usr/bin/env bash
# Hosts whose system drvPath differs between $1 and $2 (default HEAD).
set -euo pipefail
repo=$(git rev-parse --show-toplevel)

before="${1:-}"
after=$(git -C "${repo}" rev-parse --verify "${2:-HEAD}^{commit}")

all=$(fleet hosts | xargs)

# also falls back to the full fleet when $before isn't a commit this checkout knows about
# (e.g. a workflow's first-ever run, before a range against it is even meaningful)
if [ -z "$before" ] || [ "$before" = "0000000000000000000000000000000000000000" ] \
    || ! before=$(git -C "${repo}" rev-parse --verify --quiet "${before}^{commit}"); then
    echo "$all"
    exit 0
fi

drvs() {
    nix eval --json "git+file://${repo}?rev=$1#nixosConfigurations" \
        --apply 'cs: builtins.mapAttrs (_: c: c.config.system.build.toplevel.drvPath) cs'
}

head=$(drvs "$after")
base=$(drvs "$before") || {
    echo "base eval failed at ${before}; building every host" >&2
    echo "$all"
    exit 0
}

jq -nr --argjson b "$base" --argjson h "$head" --arg all "$all" \
    '$all | split(" ") | map(select($h[.] != $b[.])) | join(" ")'
