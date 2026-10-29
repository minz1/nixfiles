#!/usr/bin/env bash
# Uses -target=, never a bare `tofu destroy` — that ignores for_each narrowing and destroys everything.
set -euo pipefail

host="${1:?usage: tofu-destroy-host.sh <hostname>}"

kind=$(nix eval --raw "${ROOT_DIR}#fleet.nodes.\"${host}\".kind")
TF_VAR_fleet=$(nix eval --json "${ROOT_DIR}#fleet")
export TF_VAR_fleet

instance_resource="incus_instance.vm"
if [ "$kind" = "incus-container" ]; then
    instance_resource="incus_instance.container"
fi

cd "${ROOT_DIR}"
"${ROOT_DIR}/scripts/with-incus.sh" "sops exec-env ${ROOT_DIR}/secrets/tofu.env 'tofu -chdir=${ROOT_DIR}/tofu/infra destroy -target=${instance_resource}[\\\"${host}\\\"] -target=incus_storage_volume.persist[\\\"${host}\\\"]'"
