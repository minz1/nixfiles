#!/usr/bin/env bash
set -uo pipefail

mapfile -t phases < <(just deploy _phases)
total="${#phases[@]}"
want=("$@")
failed=()

pending_after() {
    local from=$1
    for ((j = from; j < total; j++)); do
        read -ra rest <<< "${phases[$j]}"
        for h in "${rest[@]}"; do
            if [ "${#want[@]}" -eq 0 ]; then
                return 0
            fi
            for w in "${want[@]}"; do
                [ "$h" = "$w" ] && return 0
            done
        done
    done
    return 1
}

for ((i = 0; i < total; i++)); do
    read -ra all_hosts <<< "${phases[$i]}"
    phase_hosts=()
    for h in "${all_hosts[@]}"; do
        if [ "${#want[@]}" -eq 0 ]; then
            phase_hosts+=("$h")
        else
            for w in "${want[@]}"; do
                [ "$h" = "$w" ] && phase_hosts+=("$h")
            done
        fi
    done
    [ "${#phase_hosts[@]}" -eq 0 ] && continue

    echo "==> Phase $i: ${phase_hosts[*]}"
    phase_failed=()
    deployed_hosts=()
    for host in "${phase_hosts[@]}"; do
        if "${ROOT_DIR}/scripts/deploy-retry.sh" "$host"; then
            deployed_hosts+=("$host")
        else
            phase_failed+=("$host")
        fi
    done
    failed+=(${phase_failed[@]+"${phase_failed[@]}"})

    if [ "${#phase_failed[@]}" -gt 0 ] && pending_after "$((i + 1))"; then
        echo "Aborting: phase $i failed (${phase_failed[*]}) and later phases depend on it." >&2
        break
    fi

    unhealthy_hosts=()
    for host in ${deployed_hosts[@]+"${deployed_hosts[@]}"}; do
        if ! "${ROOT_DIR}/scripts/deploy-wait-healthy.sh" "$host"; then
            unhealthy_hosts+=("$host")
            failed+=("$host (unreachable after deploy)")
        fi
    done

    if [ "${#unhealthy_hosts[@]}" -gt 0 ] && pending_after "$((i + 1))"; then
        echo "Aborting: phase $i unreachable after deploy (${unhealthy_hosts[*]}) and later phases depend on it." >&2
        break
    fi
done

if [ "${#failed[@]}" -gt 0 ]; then
    echo "Failed: ${failed[*]}" >&2
    exit 1
fi
