#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "usage: $0 <file>:<key> <file>:<key> [...]" >&2
    exit 2
fi

digest() {
    sops decrypt --extract "[\"${1##*:}\"]" "${1%:*}" | sha256sum
}

first="$(digest "$1")"
shift
status=0
for ref in "$@"; do
    d="$(digest "$ref")"
    if [ "$d" != "$first" ]; then
        echo "MISMATCH $ref"
        status=1
    fi
done

if [ "$status" -eq 0 ]; then
    echo match
fi
exit "$status"
