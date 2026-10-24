#!/usr/bin/env bash
set -euo pipefail
host="$1"
attempts="${2:-3}"
# deploy-rs can exit while the remote activate (exec'd by activate-rs) still rolls back and holds the switch lock.
wait_remote_idle() {
    local deadline=$((SECONDS + 600)) rc target
    target=$(just admin _target "$host") || return 1
    while :; do
        rc=0
        ssh -o BatchMode=yes -o ConnectTimeout=5 "$target" pgrep -x activate >/dev/null 2>&1 || rc=$?
        [ "$rc" -eq 1 ] && return 0
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "${host}: activate still running or host unreachable after 600s" >&2
            return 1
        fi
        sleep 10
    done
}

for ((i = 1; i <= attempts; i++)); do
    if nix run "${ROOT_DIR}#deploy-rs" -- --skip-checks "${ROOT_DIR}#${host}"; then
        exit 0
    fi
    echo "deploy of ${host} failed (attempt ${i}/${attempts})" >&2
    [ "$i" -lt "$attempts" ] || break
    sleep 15
    wait_remote_idle || exit 1
done
exit 1
