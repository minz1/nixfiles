#!/usr/bin/env bash
set -euo pipefail
host="$1"
timeout="${2:-120}"
target=$(just admin _target "$host")
deadline=$((SECONDS + timeout))
until ssh -o BatchMode=yes -o ConnectTimeout=5 "$target" true 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
        echo "${host} did not become reachable within ${timeout}s" >&2
        exit 1
    fi
    sleep 5
done
