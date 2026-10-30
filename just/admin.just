# /run/user/$UID, just's default tempdir for shebang recipes, is mounted noexec on many systems (e.g. WSL2) which makes every shebang recipe below fail with EACCES.
set tempdir := "/tmp"

flake := justfile_directory()

# Fleet administration: health, reboots, builds and checks. Nix store GC runs on every host via nix.gc; disk usage is alerted on by obs-0. SSH targets are resolved via the deploy-rs flake output so IP-resolution logic is never duplicated here.

# Resolve `user@host` SSH target for a node from the deploy.nodes flake output.
[private]
_target host:
    @nix run {{ flake }}#fleet-cli -- target {{ host }}

# Reboot a single host and wait for it to come back healthy.
reboot host:
    #!/usr/bin/env bash
    set -euo pipefail
    target=$(just admin _target {{ host }})
    echo "==> Rebooting {{ host }} ($target)"
    ssh "$target" 'sudo reboot' || true
    echo "Waiting for {{ host }} to come back..."
    nix run {{ flake }}#deploy-wait-healthy -- {{ host }} 180

# Fleet-wide health check: failed units, crash-looping services, obs-0 functional probes. The post-deploy gate; OBS-6 alerts cover ongoing detection.
health:
    nix run {{ flake }}#health-check

# Reboot the full fleet (VPSes, then the Incus host, whose guests autostart with it).
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
