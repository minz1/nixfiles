#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "usage: fleet hosts [--kind <kind>] | phases | target <host> | address <node>" >&2
    exit 2
}

lookup() {
    jq -er --arg k "$2" ".${1}[\$k] // empty" "$FLEET_JSON" || {
        echo "fleet: unknown host $2" >&2
        exit 1
    }
}

case "${1:-}" in
    hosts)
        case "$#" in
            1) jq -r '.targets | keys[]' "$FLEET_JSON" ;;
            3)
                [ "$2" = --kind ] || usage
                jq -r --arg k "$3" '.nodes as $n | .targets | keys[] | select($n[.].kind == $k)' "$FLEET_JSON"
                ;;
            *) usage ;;
        esac
        ;;
    phases) jq -r '.phases[] | join(" ")' "$FLEET_JSON" ;;
    target)
        [ "$#" -eq 2 ] || usage
        lookup targets "$2"
        ;;
    address)
        [ "$#" -eq 2 ] || usage
        lookup addresses "$2"
        ;;
    *) usage ;;
esac
