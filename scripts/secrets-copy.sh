#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 3 ]; then
    echo "usage: $0 <dest.yaml> <src-file> <key> [<key>...]" >&2
    exit 2
fi

dest="$1"
src="$2"
shift 2

for key in "$@"; do
    if [ -f "$dest" ]; then
        sops decrypt --extract "[\"$key\"]" "$src" | jq -Rs . | sops set --value-stdin "$dest" "[\"$key\"]"
    else
        tmp="$(mktemp "$(dirname "$dest")/.secrets-copy.XXXXXX")"
        sops decrypt --extract "[\"$key\"]" "$src" \
            | jq -Rs --arg k "$key" '{($k): .}' \
            | sops encrypt --filename-override "$dest" --input-type json --output-type yaml /dev/stdin > "$tmp"
        mv "$tmp" "$dest"
    fi
    echo "copied $key -> $dest"
done
