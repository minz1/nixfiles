#!/usr/bin/env bash
# Uses -target=, never a bare `tofu destroy` — that ignores for_each narrowing and destroys everything.
set -euo pipefail

host="${1:?usage: tofu-destroy-host.sh <hostname>}"

incus_type=$(nix eval --raw --impure --expr "
  let t = import ${ROOT_DIR}/common/topology.nix;
  in t.nodes.\"${host}\".incus.incus_type or \"virtual-machine\"
")

instance_resource="incus_instance.vm"
if [ "$incus_type" = "container" ]; then
    instance_resource="incus_instance.container"
fi

cd "${ROOT_DIR}"
"${ROOT_DIR}/scripts/with-incus.sh" "sops exec-env ${ROOT_DIR}/secrets/tofu.env 'tofu -chdir=${ROOT_DIR}/tofu/infra destroy -target=${instance_resource}[\\\"${host}\\\"] -target=incus_storage_volume.persist[\\\"${host}\\\"]'"
