# CI-only recipes: build + push to Attic. No deploy authority — see docs/main-plan.md's S7 section.

# Print the space-separated affected-host list for commits between `before` and `after`.
affected-hosts before after="HEAD":
    ${ROOT_DIR}/scripts/ci-affected-hosts.sh "{{ before }}" "{{ after }}"

# Build and push the given hosts' closures to the Attic cache.
attic-push *hosts:
    ${ROOT_DIR}/scripts/ci-attic-push.sh {{ hosts }}
