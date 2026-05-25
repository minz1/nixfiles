[private]
_with-incus command:
    ${ROOT_DIR}/scripts/with-incus.sh "{{ command }}"

init flags="":
    @just tofu _with-incus "sops exec-env ${ROOT_DIR}/secrets/rustfs-tofu.env 'tofu -chdir=${ROOT_DIR}/tofu init {{ flags }}'"

# Build the Incus bootstrap image. Produces result/nixos.qcow2 + result/metadata.tar.xz.
build-image:
    nix build ${ROOT_DIR}#incus-bootstrap-image -o ${ROOT_DIR}/result

# Import the bootstrap image directly into Incus (manual fallback, bypasses registry).
import-image: build-image
    @just tofu _with-incus "incus image import ${ROOT_DIR}/result/metadata.tar.xz ${ROOT_DIR}/result/nixos.qcow2 --alias nixos-bootstrap"

# Usage: just tofu plan [hostname]
plan hostname="":
    @just tofu _with-incus "sops exec-env ${ROOT_DIR}/secrets/rustfs-tofu.env 'tofu -chdir=${ROOT_DIR}/tofu plan -var=\"hostname={{ hostname }}\" -out=${ROOT_DIR}/tofu/tofu.plan'"

apply:
    @just tofu _with-incus "sops exec-env ${ROOT_DIR}/secrets/rustfs-tofu.env 'tofu -chdir=${ROOT_DIR}/tofu apply ${ROOT_DIR}/tofu/tofu.plan'"

destroy hostname:
    @just tofu _with-incus "sops exec-env ${ROOT_DIR}/secrets/rustfs-tofu.env 'tofu -chdir=${ROOT_DIR}/tofu destroy -var=\"hostname={{ hostname }}\"'"

# Build the bootstrap image and publish it to the S3 simplestreams registry.
# Run this before `just tofu plan` whenever the bootstrap image changes.
# Prerequisites: rustfs-bucket-setup must have already created the incus-images bucket.
publish-image: build-image
    ${ROOT_DIR}/scripts/tofu-publish-image.sh
