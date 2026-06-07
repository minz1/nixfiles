export ROOT_DIR := justfile_directory()

mod bootstrap "just/bootstrap.just"
mod deploy "just/deploy.just"
mod tofu "just/tofu.just"

sops-edit node:
    sops secrets/{{ node }}.yaml

setup-dev-ca:
    sudo cp "{{ ROOT_DIR }}/hosts/minz-pki-0/root_ca.crt" /usr/local/share/ca-certificates/minz-pki-0-root.crt
    sudo update-ca-certificates
