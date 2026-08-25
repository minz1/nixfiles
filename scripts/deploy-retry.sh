#!/usr/bin/env bash
set -euo pipefail
host="$1"
attempts="${2:-3}"
for ((i = 1; i <= attempts; i++)); do
    if nix run "${ROOT_DIR}#deploy-rs" -- "${ROOT_DIR}#${host}"; then
        exit 0
    fi
    echo "deploy of ${host} failed (attempt ${i}/${attempts})" >&2
    sleep 15
done
exit 1
