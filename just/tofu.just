[private]
_with-incus command:
    ${ROOT_DIR}/scripts/with-incus.sh "{{ command }}"

init flags="":
    @just tofu _with-incus "sops exec-env secrets/rustfs-tofu.env 'tofu -chdir=tofu init {{ flags }}'"

# Build the Incus bootstrap image. Produces result/nixos.qcow2 + result/metadata.tar.xz.
build-image:
    nix build .#incus-bootstrap-image -o result

# Import the bootstrap image into Incus as alias "nixos-bootstrap".
import-image: build-image
    @just tofu _with-incus "incus image import result/metadata.tar.xz result/nixos.qcow2 --alias nixos-bootstrap"

# Usage: just tofu plan [hostname]
plan hostname="": build-image
    @just tofu _with-incus "sops exec-env secrets/rustfs-tofu.env 'tofu -chdir=tofu plan -var=\"hostname={{ hostname }}\" -out=tofu.plan'"

apply: build-image
    @just tofu _with-incus "sops exec-env secrets/rustfs-tofu.env 'tofu -chdir=tofu apply tofu.plan'"

destroy hostname: build-image
    @just tofu _with-incus "sops exec-env secrets/rustfs-tofu.env 'tofu -chdir=tofu destroy -var=\"hostname={{ hostname }}\"'"
