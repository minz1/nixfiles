[private]
_with-incus command:
    ${ROOT_DIR}/scripts/with-incus.sh "{{ command }}"

# --- infra workspace (Incus VMs, buckets, images) ---

infra-init flags="":
    @just tofu _with-incus "sops exec-env ${ROOT_DIR}/secrets/rustfs-tofu.env 'tofu -chdir=${ROOT_DIR}/tofu/infra init {{ flags }}'"

# Usage: just tofu infra-plan [hostname]
infra-plan hostname="":
    @just tofu _with-incus "sops exec-env ${ROOT_DIR}/secrets/rustfs-tofu.env 'tofu -chdir=${ROOT_DIR}/tofu/infra plan -var=\"hostname={{ hostname }}\" -out=${ROOT_DIR}/tofu/infra/tofu.plan'"

infra-apply:
    @just tofu _with-incus "sops exec-env ${ROOT_DIR}/secrets/rustfs-tofu.env 'tofu -chdir=${ROOT_DIR}/tofu/infra apply ${ROOT_DIR}/tofu/infra/tofu.plan'"

infra-destroy hostname:
    @just tofu _with-incus "sops exec-env ${ROOT_DIR}/secrets/rustfs-tofu.env 'tofu -chdir=${ROOT_DIR}/tofu/infra destroy -var=\"hostname={{ hostname }}\"'"

# Build the Incus bootstrap image. Produces result/nixos.qcow2 + result/metadata.tar.xz.
build-image:
    nix build ${ROOT_DIR}#incus-bootstrap-image -o ${ROOT_DIR}/result

# Import the bootstrap image directly into Incus (manual fallback, bypasses registry).
import-image: build-image
    @just tofu _with-incus "incus image import ${ROOT_DIR}/result/metadata.tar.xz ${ROOT_DIR}/result/nixos.qcow2 --alias nixos-bootstrap"

# Build the bootstrap image and publish it to the S3 simplestreams registry.
# Run this before `just tofu infra-plan` whenever the bootstrap image changes.
# Prerequisites: rustfs-bucket-setup must have already created the incus-images bucket.
publish-image: build-image
    ${ROOT_DIR}/scripts/tofu-publish-image.sh

# --- app workspace (Authentik OIDC providers, groups, etc.) ---

app-init flags="":
    sops exec-env ${ROOT_DIR}/secrets/rustfs-tofu.env 'tofu -chdir=${ROOT_DIR}/tofu/app init {{ flags }}'

app-plan:
    sops exec-env ${ROOT_DIR}/secrets/rustfs-tofu.env 'tofu -chdir=${ROOT_DIR}/tofu/app plan -out=${ROOT_DIR}/tofu/app/tofu.plan'

app-apply:
    sops exec-env ${ROOT_DIR}/secrets/rustfs-tofu.env 'tofu -chdir=${ROOT_DIR}/tofu/app apply ${ROOT_DIR}/tofu/app/tofu.plan'

# Print the generated Grafana client_secret — paste into sops secrets/minz-obs-0.yaml
app-client-secret:
    sops exec-env ${ROOT_DIR}/secrets/rustfs-tofu.env 'tofu -chdir=${ROOT_DIR}/tofu/app output -raw grafana_client_secret'
