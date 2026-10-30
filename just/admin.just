# /run/user/$UID, just's default tempdir for shebang recipes, is mounted noexec on many systems (e.g. WSL2) which makes every shebang recipe below fail with EACCES.
set tempdir := "/tmp"

flake := justfile_directory()

# Fleet administration: disk usage reporting and Nix store GC. SSH targets are resolved via the deploy-rs flake output so IP-resolution logic is never duplicated here.

# Resolve `user@host` SSH target for a node from the deploy.nodes flake output.
[private]
_target host:
    @nix run {{ flake }}#fleet-cli -- target {{ host }}

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
    nix run {{ flake }}#deploy-wait-healthy -- {{ host }} 180

# Fleet-wide health check: failed units, crash-looping services, obs-0 functional probes. Not wired into deploy.
health:
    nix run {{ flake }}#health-check

# Reboot the full fleet (standalone hosts, then home-nix-0 which cascades its Incus guests).
reboot-all:
    nix run {{ flake }}#reboot-fleet

# Update flake inputs, then build every host closure so hash breakage (e.g. a pkgs.caddy.withPlugins vendor hash going stale) surfaces now, not at deploy time. Does not touch anything outside flake.lock.
update:
    nix flake update --flake "{{ flake }}"
    just admin build-all

# Build every host's system closure.
build-all:
    nix build --no-link $(just deploy list | sed "s|.*|{{ flake }}#nixosConfigurations.&.config.system.build.toplevel|")

# Fail if anything tracked under secrets/ isn't sops-encrypted.
check-secrets:
    nix run {{ flake }}#check-secrets-encrypted

# nix flake check (script tests and shellcheck included) + formatting. Read-only; run before committing.
check:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "==> nix flake check"
    nix flake check "{{ flake }}"
    echo "==> nix fmt --fail-on-change"
    nix fmt -- --fail-on-change "{{ flake }}"
    echo "==> secrets/ encrypted"
    nix run {{ flake }}#check-secrets-encrypted
