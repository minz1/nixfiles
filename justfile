mod admin "just/admin.just"
mod bootstrap "just/bootstrap.just"
mod ci "just/ci.just"
mod deploy "just/deploy.just"
mod tofu "just/tofu.just"

sops-edit node:
    sops secrets/{{ node }}.yaml

setup-dev-ca:
    sudo cp "{{ justfile_directory() }}/hosts/minz-pki-0/root_ca.crt" /usr/local/share/ca-certificates/minz-pki-0-root.crt
    sudo update-ca-certificates

topology:
    nix build .#topology.x86_64-linux.config.output -o result-topology
    @echo "SVGs at {{ justfile_directory() }}/result-topology/{main,network}.svg"
