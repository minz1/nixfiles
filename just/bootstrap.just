flake := justfile_directory()

# Generates a fresh SSH host key in RAM and prints the age pubkey for .sops.yaml.
keygen node:
    nix run {{ flake }}#bootstrap-keygen -- "{{ node }}"

# Writes the in-RAM private key into secrets/<node>.yaml.
store-key node:
    nix run {{ flake }}#bootstrap-store-key -- "{{ node }}"

[private]
_extract-key node:
    nix run {{ flake }}#bootstrap-extract-key -- "{{ node }}"

# Provision a bare-metal or cloud host. Also writes hosts/<node>/hardware-configuration.nix.
install node ip: (_extract-key node)
    nix run {{ flake }}#bootstrap-install -- "{{ node }}" "{{ ip }}"

# Provision an Incus VM. IP resolved from topology.
install-vm node: (_extract-key node)
    nix run {{ flake }}#bootstrap-install-vm -- "{{ node }}"
