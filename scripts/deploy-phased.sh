#!/usr/bin/env bash
set -uo pipefail
repo=$(git rev-parse --show-toplevel) || exit 1

phases_out=$(fleet phases) || exit 1
mapfile -t phases <<< "$phases_out"
total="${#phases[@]}"
want=("$@")
for w in "$@"; do
    tr ' ' '\n' <<< "$phases_out" | grep -qxF -- "$w" || {
        echo "Unknown host: $w" >&2
        exit 1
    }
done
failed=()

selected=()
attic_phase=-1
for ((i = 0; i < total; i++)); do
    read -ra hs <<< "${phases[$i]}"
    for h in "${hs[@]}"; do
        # shortcut: binary-cache host name hardcoded as in verify-attic-closure.sh, replaced by the binary-cache role tag in OPS-5 A2
        [ "$h" = minz-attic-0 ] && attic_phase=$i
        if [ "${#want[@]}" -eq 0 ]; then
            selected+=("$h")
        else
            for w in "${want[@]}"; do
                [ "$h" = "$w" ] && {
                    selected+=("$h")
                    break
                }
            done
        fi
    done
done

attrs=()
for h in "${selected[@]}"; do
    attrs+=("${repo}#nixosConfigurations.${h}.config.system.build.toplevel")
done
built=$(nix build --no-link --print-out-paths "${attrs[@]}") || {
    echo "Build failed; nothing deployed." >&2
    exit 1
}

declare -A path_of=()
for h in "${selected[@]}"; do
    matches=$(grep -F -- "-nixos-system-${h}-" <<< "$built" || true)
    if [ -z "$matches" ] || [ "$(wc -l <<< "$matches")" -ne 1 ]; then
        echo "Expected exactly one built system for ${h}, got: ${matches:-none}. Nothing deployed." >&2
        exit 1
    fi
    path_of[$h]=$matches
done

pending_after() {
    local from=$1
    for ((j = from; j < total; j++)); do
        read -ra rest <<< "${phases[$j]}"
        for h in "${rest[@]}"; do
            [[ -v path_of[$h] ]] && return 0
        done
    done
    return 1
}

attic_ok() {
    local host=$1 phase=$2 rc=0
    [ "${SKIP_ATTIC_VERIFY:-0}" = "1" ] && return 0
    verify-attic-closure "$host" "${path_of[$host]}" || rc=$?
    [ "$rc" -eq 0 ] && return 0
    if [ "$rc" -eq 2 ] && [ "$phase" -le "$attic_phase" ]; then
        echo "${host}: Attic unreachable; deploying anyway (phase at or before the binary cache)" >&2
        return 0
    fi
    return 1
}

for ((i = 0; i < total; i++)); do
    read -ra all_hosts <<< "${phases[$i]}"
    phase_hosts=()
    for h in "${all_hosts[@]}"; do
        [[ -v path_of[$h] ]] && phase_hosts+=("$h")
    done
    [ "${#phase_hosts[@]}" -eq 0 ] && continue

    echo "==> Phase $i: ${phase_hosts[*]}"
    phase_failed=()
    deployed_hosts=()
    for host in "${phase_hosts[@]}"; do
        if ! attic_ok "$host" "$i"; then
            phase_failed+=("$host (attic verify failed)")
            continue
        fi
        if deploy-retry "$host"; then
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
        if ! deploy-wait-healthy "$host"; then
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
