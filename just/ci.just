flake := justfile_directory()

# CI-only recipes: build + push to Attic. No deploy authority.

# Print the space-separated affected-host list for commits between `before` and `after`.
affected-hosts before after="HEAD":
    nix run {{ flake }}#ci-affected-hosts -- "{{ before }}" "{{ after }}"

# Build the given hosts' closures and record their paths for attic-push.
build *hosts:
    nix run {{ flake }}#ci-build -- {{ hosts }}

# Push the paths recorded by build (or flake-update) to Attic. Needs ATTIC_PUSH_TOKEN.
attic-push:
    nix run {{ flake }}#ci-attic-push

# Scan the given hosts' closures with vulnix, KEV-gated. Defaults to every deployed host.
vulnix *hosts:
    nix run {{ flake }}#ci-vulnix -- {{ hosts }}

# Bump flake.lock and build every deployed host's closure (the workflow pushes separately). Leaves flake.lock updated for the workflow to upload as an artifact.
flake-update:
    nix run {{ flake }}#ci-flake-update
