#!/usr/bin/env bash
set -uo pipefail

# Reboot order: standalone hosts first, then the Incus host last — its reboot cascades all 6 guest VMs/containers automatically via boot.autostart=last-state.
standalone=(minz-vultr-nix-0 minz-vultr-nix-1)
incus_host=minz-home-nix-0
incus_guests=(minz-obs-0 minz-authentik-0 minz-pki-0 minz-game-0 minz-services-0 minz-media-0)

reboot_and_wait() {
    local host="$1" target deadline
    target=$(just admin _target "$host")
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
    if "${ROOT_DIR}/scripts/deploy-wait-healthy.sh" "$host" 180; then
        echo "$host back up"
    else
        echo "$host FAILED to come back" >&2
        return 1
    fi
}

failed=()

for h in "${standalone[@]}"; do
    reboot_and_wait "$h" || failed+=("$h")
done

reboot_and_wait "$incus_host" || failed+=("$incus_host")

echo "==> Waiting for Incus guests to autostart on $incus_host..."
for h in "${incus_guests[@]}"; do
    "${ROOT_DIR}/scripts/deploy-wait-healthy.sh" "$h" 180 && echo "$h back up" || failed+=("$h")
done

if [ "${#failed[@]}" -gt 0 ]; then
    echo "Failed: ${failed[*]}" >&2
    exit 1
fi

echo "Fleet reboot complete."
