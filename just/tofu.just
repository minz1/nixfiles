init flags="":
    @./scripts/with-incus.sh "sops exec-env secrets/rustfs-tofu.env 'tofu -chdir=tofu init {{ flags }}'"

# Build the Incus bootstrap image. Produces result/nixos.qcow2 + result/metadata.tar.xz.
build-image:
    nix build .#incus-bootstrap-image -o result

# Import the bootstrap image into Incus as alias "nixos-bootstrap".
import-image: build-image
    @./scripts/with-incus.sh "incus image import result/metadata.tar.xz result/nixos.qcow2 --alias nixos-bootstrap"

# Usage: just tofu plan [hostname]
plan hostname="": build-image
    @./scripts/with-incus.sh "sops exec-env secrets/rustfs-tofu.env 'tofu -chdir=tofu plan -var=\"hostname={{ hostname }}\" -out=tofu.plan'"

apply: build-image
    @./scripts/with-incus.sh "sops exec-env secrets/rustfs-tofu.env 'tofu -chdir=tofu apply tofu.plan'"

destroy hostname: build-image
    @./scripts/with-incus.sh "sops exec-env secrets/rustfs-tofu.env 'tofu -chdir=tofu destroy -var=\"hostname={{ hostname }}\"'"
