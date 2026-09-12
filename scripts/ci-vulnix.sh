#!/usr/bin/env bash
set -euo pipefail

whitelist="${ROOT_DIR}/config/vulnix-whitelist.toml"
kev_url="https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"

hosts=("$@")
if [ "${#hosts[@]}" -eq 0 ]; then
    mapfile -t hosts < <(just deploy list)
fi

kev_ids=$(curl -fsSL "$kev_url" | jq -c '[.vulnerabilities[].cveID]')

any_kev=0
for host in "${hosts[@]}"; do
    drv=$(nix path-info --derivation "${ROOT_DIR}#nixosConfigurations.${host}.config.system.build.toplevel")

    findings=$(nix shell nixpkgs#vulnix --command vulnix --json -w "$whitelist" "$drv") || true
    if [ -z "$findings" ]; then
        echo "vulnix produced no output for $host" >&2
        any_kev=1
        continue
    fi

    echo "== $host =="
    echo "$findings" | jq -r \
        '.[] | .affected_by[] as $cve | [$cve, .pname, .version, (.cvssv3_basescore[$cve] // "?")] | @tsv' \
        | sort -u | column -t

    host_kev=$(echo "$findings" | jq -r --argjson kev "$kev_ids" \
        '[.[] | .affected_by[] | select(. as $c | $kev | index($c))] | unique | .[]')
    if [ -n "$host_kev" ]; then
        echo "KEV match on $host:" >&2
        echo "  ${host_kev//$'\n'/$'\n  '}" >&2
        any_kev=1
    fi
done

exit "$any_kev"
