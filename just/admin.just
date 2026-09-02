# /run/user/$UID (XDG_RUNTIME_DIR), just's default tempdir for shebang
# recipes, is mounted noexec on many systems (e.g. WSL2, systemd user
# sessions) which makes every shebang recipe below fail with EACCES.
set tempdir := "/tmp"

# Fleet administration: disk usage reporting and Nix store GC.
# SSH targets are resolved via the deploy-rs flake output so IP-resolution
# logic (mgmt vs incus_bridge IP) is never duplicated here.

# Resolve `user@host` SSH target for a node from the deploy.nodes flake output.
[private]
_target host:
    @nix eval --raw ${ROOT_DIR}#deploy.nodes.{{ host }} --apply 'n: "${n.sshUser}@${n.hostname}"'

# Show root/nix/persist disk usage, Nix store size, and system generation count on one host.
disk-usage host:
    #!/usr/bin/env bash
    set -euo pipefail
    target=$(just admin _target {{ host }})
    echo "==> {{ host }} ($target)"
    ssh "$target" '
      echo "--- df -h ---"
      df -h / 2>/dev/null || true
      df -h /nix 2>/dev/null || true
      df -h /persist 2>/dev/null || true
      echo
      echo "--- /nix/store size ---"
      du -sh /nix/store 2>/dev/null || true
      echo
      echo "--- system generations ---"
      sudo nix-env --list-generations -p /nix/var/nix/profiles/system
    '

# Run disk-usage on every deployed node, continuing past per-host failures.
disk-usage-all:
    #!/usr/bin/env bash
    set -uo pipefail
    failed=()
    for host in $(just deploy list); do
      just admin disk-usage "$host" || failed+=("$host")
      echo
    done
    if [ "${#failed[@]}" -gt 0 ]; then
      echo "Failed: ${failed[*]}" >&2
      exit 1
    fi

# Prune generations older than `older_than`, GC, and optimise the store on one host.
gc host older_than="14d":
    #!/usr/bin/env bash
    set -euo pipefail
    target=$(just admin _target {{ host }})
    echo "==> {{ host }} ($target): pruning generations older than {{ older_than }}, GC + optimise"
    ssh "$target" '
      sudo nix-collect-garbage --delete-older-than {{ older_than }}
      sudo nix-store --optimise
      echo
      echo "--- df -h after gc ---"
      df -h / 2>/dev/null || true
      df -h /nix 2>/dev/null || true
    '

# Run gc on every deployed node, continuing past per-host failures.
gc-all older_than="14d":
    #!/usr/bin/env bash
    set -uo pipefail
    failed=()
    for host in $(just deploy list); do
      just admin gc "$host" {{ older_than }} || failed+=("$host")
      echo
    done
    if [ "${#failed[@]}" -gt 0 ]; then
      echo "Failed: ${failed[*]}" >&2
      exit 1
    fi

# Reboot a single host and wait for it to come back healthy.
reboot host:
    #!/usr/bin/env bash
    set -euo pipefail
    target=$(just admin _target {{ host }})
    echo "==> Rebooting {{ host }} ($target)"
    ssh "$target" 'sudo reboot' || true
    echo "Waiting for {{ host }} to come back..."
    ${ROOT_DIR}/scripts/deploy-wait-healthy.sh {{ host }} 180

# Fleet-wide health check: failed units, crash-looping services, obs-0 functional probes. Not wired into deploy.
health:
    ${ROOT_DIR}/scripts/health-check.sh

# Reboot the full fleet (standalone hosts, then home-nix-0 which cascades its Incus guests).
reboot-all:
    ${ROOT_DIR}/scripts/reboot-fleet.sh
