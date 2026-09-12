#!/usr/bin/env bash
# Bumps flake.lock, builds every deployed host's closure against it, and pushes them to
# Attic. Leaves flake.lock updated on disk for the workflow to upload as an artifact — CI
# never pushes to git, a human reviews and commits the bump.
set -euo pipefail

nix flake update

mapfile -t hosts < <(just deploy list)
"${ROOT_DIR}/scripts/ci-attic-push.sh" "${hosts[@]}"
