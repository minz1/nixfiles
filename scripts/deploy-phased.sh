#!/usr/bin/env bash
set -uo pipefail

phases_out=$(just deploy _phases) || exit 1
mapfile -t phases <<< "$phases_out"
total="${#phases[@]}"
want=("$@")
for w in "$@"; do
    tr ' ' '\n' <<< "$phases_out" | grep -qxF -- "$w" || { echo "Unknown host: $w" >&2; exit 1; }
done
failed=()

selected=()
attic_phase=-1
declare -A phase_of=()
for ((i = 0; i < total; i++)); do
    read -ra hs <<< "${phases[$i]}"
    for h in "${hs[@]}"; do
        phase_of[$h]=$i
        # shortcut: binary-cache host name hardcoded as in verify-attic-closure.sh, replaced by fleet data in OPS-5 B
        [ "$h" = minz-attic-0 ] && attic_phase=$i
        if [ "${#want[@]}" -eq 0 ]; then
            selected+=("$h")
        else
            for w in "${want[@]}"; do
                [ "$h" = "$w" ] && selected+=("$h")
            done
        fi
    done
done

attrs=()
for h in "${selected[@]}"; do
    attrs+=("${ROOT_DIR}#nixosConfigurations.${h}.config.system.build.toplevel")
done
built=$(nix build --no-link --print-out-paths "${attrs[@]}") || { echo "Build failed; nothing deployed." >&2; exit 1; }

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

attic_ok() {
    local host=$1 rc=0
    [ "${SKIP_ATTIC_VERIFY:-0}" = "1" ] && return 0
    "${ROOT_DIR}/scripts/verify-attic-closure.sh" "$host" "${path_of[$host]}" || rc=$?
    [ "$rc" -eq 0 ] && return 0
    if [ "$rc" -eq 2 ] && [ "${phase_of[$host]}" -le "$attic_phase" ]; then
        echo "${host}: Attic unreachable; deploying anyway (phase at or before the binary cache)" >&2
        return 0
    fi
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
        if ! attic_ok "$host"; then
            phase_failed+=("$host (attic verify failed)")
            continue
        fi
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
