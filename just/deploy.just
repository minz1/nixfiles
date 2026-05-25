# Deploy a single node with auto-rollback on failure.
node host:
    nix run ${ROOT_DIR}#deploy-rs -- ${ROOT_DIR}#{{ host }}

# Deploy all nodes.
all:
    nix run ${ROOT_DIR}#deploy-rs -- ${ROOT_DIR}

# List all nodes defined in the flake.
list:
    @nix eval --raw ${ROOT_DIR}#deploy.nodes --apply 'x: (builtins.concatStringsSep "\n" (builtins.attrNames x)) + "\n"'
