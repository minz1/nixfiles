# OpenTofu infrastructure management

[private]
_with-incus command:
    ${ROOT_DIR}/scripts/with-incus.sh "{{ command }}"

# Build the Incus VM bootstrap image. Produces result/nixos.qcow2 + result/metadata.tar.xz.
build-image:
    nix build ${ROOT_DIR}#incus-bootstrap-image -o ${ROOT_DIR}/result

# Build the Incus container bootstrap image. Produces result-container/rootfs.tar.xz + result-container/metadata.tar.xz.
build-container-image:
    nix build ${ROOT_DIR}#incus-bootstrap-container-image -o ${ROOT_DIR}/result-container

# Import the VM bootstrap image directly into Incus (manual fallback, bypasses registry).
# import-image: build-image
#     @just tofu _with-incus "incus image import ${ROOT_DIR}/result/metadata.tar.xz ${ROOT_DIR}/result/nixos.qcow2 --alias nixos-bootstrap"

# Import the container bootstrap image directly into Incus (manual fallback, bypasses registry).
# import-container-image: build-container-image
#     @just tofu _with-incus "incus image import ${ROOT_DIR}/result-container/metadata.tar.xz ${ROOT_DIR}/result-container/rootfs.tar.xz --alias nixos-bootstrap-container"

publish-image: build-image build-container-image
    ${ROOT_DIR}/scripts/tofu-publish-image.sh

# --- Infra layer ---

infra-init flags="":
    @just tofu _with-incus "sops exec-env ${ROOT_DIR}/secrets/tofu.env 'tofu -chdir=${ROOT_DIR}/tofu/infra init {{ flags }}'"

infra-plan hostname="":
    @just tofu _with-incus "sops exec-env ${ROOT_DIR}/secrets/tofu.env 'tofu -chdir=${ROOT_DIR}/tofu/infra plan -var=\"hostname={{ hostname }}\" -out=${ROOT_DIR}/tofu/infra/tofu.plan'"

infra-apply:
    @just tofu _with-incus "sops exec-env ${ROOT_DIR}/secrets/tofu.env 'tofu -chdir=${ROOT_DIR}/tofu/infra apply ${ROOT_DIR}/tofu/infra/tofu.plan'"

infra-destroy hostname="":
    @just tofu _with-incus "sops exec-env ${ROOT_DIR}/secrets/tofu.env 'tofu -chdir=${ROOT_DIR}/tofu/infra destroy -var=\"hostname={{ hostname }}\"'"

# --- App layer ---

app-init flags="":
    sops exec-env ${ROOT_DIR}/secrets/tofu.env 'tofu -chdir=${ROOT_DIR}/tofu/app init {{ flags }}'

app-plan:
    sops exec-env ${ROOT_DIR}/secrets/tofu.env 'tofu -chdir=${ROOT_DIR}/tofu/app plan -out=${ROOT_DIR}/tofu/app/tofu.plan'

app-apply:
    sops exec-env ${ROOT_DIR}/secrets/tofu.env 'tofu -chdir=${ROOT_DIR}/tofu/app apply ${ROOT_DIR}/tofu/app/tofu.plan'
