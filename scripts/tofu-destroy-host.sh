#!/usr/bin/env bash
# Uses -target=, never a bare `tofu destroy` — that ignores for_each narrowing and destroys everything.
set -euo pipefail
repo=$(git rev-parse --show-toplevel)

host="${1:?usage: tofu-destroy-host.sh <hostname>}"

TF_VAR_fleet=$(nix eval --json "${repo}#fleet")
kind=$(jq -er --arg h "$host" '.nodes[$h].kind' <<< "$TF_VAR_fleet") || { echo "unknown host: $host" >&2; exit 1; }
export TF_VAR_fleet

instance_resource="incus_instance.vm"
if [ "$kind" = "incus-container" ]; then
    instance_resource="incus_instance.container"
fi

cd "${repo}"
with-incus "sops exec-env ${repo}/secrets/tofu.env 'tofu -chdir=${repo}/tofu/infra destroy -target=${instance_resource}[\\\"${host}\\\"] -target=incus_storage_volume.persist[\\\"${host}\\\"]'"
