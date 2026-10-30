#!/usr/bin/env bash
set -uo pipefail

reboot_and_wait() {
    local host="$1" target deadline
    target=$(fleet target "$host")
    echo "==> Rebooting $host ($target)"
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$target" 'sudo reboot' || true

    echo "Waiting for $host to go down..."
    deadline=$((SECONDS + 60))
    while ssh -o BatchMode=yes -o ConnectTimeout=3 "$target" true 2>/dev/null; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "$host did not go down within 60s — continuing anyway" >&2
            break
        fi
        sleep 2
    done

    echo "Waiting for $host to come back..."
    if deploy-wait-healthy "$host" 180; then
        echo "$host back up"
    else
        echo "$host FAILED to come back" >&2
        return 1
    fi
}

mapfile -t vps < <(fleet hosts --kind vps)
mapfile -t incus_hosts < <(fleet hosts --kind incus-host)
mapfile -t guests < <(fleet hosts --kind incus-vm; fleet hosts --kind incus-container)

failed=()

for h in "${vps[@]}" "${incus_hosts[@]}"; do
    reboot_and_wait "$h" || failed+=("$h")
done

# Guests come back with their Incus host (boot.autostart=last-state).
echo "==> Waiting for Incus guests to autostart..."
for h in "${guests[@]}"; do
    deploy-wait-healthy "$h" 180 && echo "$h back up" || failed+=("$h")
done

if [ "${#failed[@]}" -gt 0 ]; then
    echo "Failed: ${failed[*]}" >&2
    exit 1
fi

echo "Fleet reboot complete."
