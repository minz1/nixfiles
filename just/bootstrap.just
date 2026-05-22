# Generates a fresh SSH host key in RAM and prints the age pubkey for .sops.yaml.
keygen node:
    ./scripts/bootstrap-keygen.sh "{{ node }}"

# Writes the in-RAM private key into secrets/<node>.yaml.
store-key node:
    ./scripts/bootstrap-store-key.sh "{{ node }}"

[private]
_extract-key node:
    ./scripts/bootstrap-extract-key.sh "{{ node }}"

# Provision a bare-metal or cloud host. Also writes hosts/<node>/hardware-configuration.nix.
install node ip: (_extract-key node)
    nix run .#nixos-anywhere -- \
        --flake .#{{ node }} \
        --extra-files /dev/shm/nixos-bootstrap-{{ node }} \
        --generate-hardware-config nixos-generate-config hosts/{{ node }}/hardware-configuration.nix \
        root@{{ ip }}
    rm -rf /dev/shm/nixos-bootstrap-{{ node }}

# Provision an Incus VM. IP resolved from topology.
install-vm node: (_extract-key node)
    nix run .#nixos-anywhere -- \
        --flake .#{{ node }} \
        --extra-files /dev/shm/nixos-bootstrap-{{ node }} \
        minz1@$(nix eval --raw --impure --expr '(import ./common/topology.nix).nodes."{{ node }}".networks.incus_bridge.ip')
    rm -rf /dev/shm/nixos-bootstrap-{{ node }}
