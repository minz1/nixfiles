# Deploy a single node with auto-rollback on failure.
node host:
    nix run .#deploy-rs -- .#{{ host }}

# Deploy all nodes.
all:
    nix run .#deploy-rs -- .

# List all nodes defined in the flake.
list:
    @nix eval --raw .#deploy.nodes --apply 'x: (builtins.concatStringsSep "\n" (builtins.attrNames x)) + "\n"'
