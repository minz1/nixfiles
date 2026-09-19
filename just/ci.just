# CI-only recipes: build + push to Attic. No deploy authority — see docs/main-plan.md's S7 section.

# Print the space-separated affected-host list for commits between `before` and `after`.
affected-hosts before after="HEAD":
    ${ROOT_DIR}/scripts/ci-affected-hosts.sh "{{ before }}" "{{ after }}"

# Build the given hosts' closures and record their paths for attic-push.
build *hosts:
    ${ROOT_DIR}/scripts/ci-build.sh {{ hosts }}

# Push the paths recorded by build (or flake-update) to Attic. Needs ATTIC_PUSH_TOKEN.
attic-push:
    ${ROOT_DIR}/scripts/ci-attic-push.sh

# Scan the given hosts' closures with vulnix, KEV-gated. Defaults to every deployed host.
vulnix *hosts:
    ${ROOT_DIR}/scripts/ci-vulnix.sh {{ hosts }}

# Bump flake.lock and build every deployed host's closure (the workflow pushes separately). Leaves flake.lock updated for the workflow to upload as an artifact.
flake-update:
    ${ROOT_DIR}/scripts/ci-flake-update.sh
