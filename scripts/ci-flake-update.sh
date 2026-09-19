#!/usr/bin/env bash
# Bumps flake.lock and builds every deployed host's closure against it; the workflow's
# next step pushes them to Attic. Leaves flake.lock updated on disk for the workflow to upload as an artifact — CI
# never pushes to git, a human reviews and commits the bump.
set -euo pipefail

nix flake update

mapfile -t hosts < <(just deploy list)
"${ROOT_DIR}/scripts/ci-build.sh" "${hosts[@]}"
