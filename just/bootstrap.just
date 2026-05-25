# Generates a fresh SSH host key in RAM and prints the age pubkey for .sops.yaml.
keygen node:
    ${ROOT_DIR}/scripts/bootstrap-keygen.sh "{{ node }}"

# Writes the in-RAM private key into secrets/<node>.yaml.
store-key node:
    ${ROOT_DIR}/scripts/bootstrap-store-key.sh "{{ node }}"

[private]
_extract-key node:
    ${ROOT_DIR}/scripts/bootstrap-extract-key.sh "{{ node }}"

# Provision a bare-metal or cloud host. Also writes hosts/<node>/hardware-configuration.nix.
install node ip: (_extract-key node)
    ${ROOT_DIR}/scripts/bootstrap-install.sh "{{ node }}" "{{ ip }}"

# Provision an Incus VM. IP resolved from topology.
install-vm node: (_extract-key node)
    ${ROOT_DIR}/scripts/bootstrap-install-vm.sh "{{ node }}"
