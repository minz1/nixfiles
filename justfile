# nixfiles — command reference
# Install just: https://github.com/casey/just
# ── OpenTofu ──────────────────────────────────────
# Run tofu commands against the home VM's Incus daemon

tofu-init:
    cd tofu && tofu init

tofu-plan: tofu-init
    cd tofu && INCUS_REMOTE=home-vm tofu plan

tofu-apply: tofu-init
    cd tofu && INCUS_REMOTE=home-vm tofu apply

tofu-export:
    cd tofu && INCUS_REMOTE=home-vm tofu output | sort | perl -ne 'chomp; s/_/./g; print "  $$_;\n"' > ../common/vm-ips.nix

tofu-all: tofu-apply tofu-export
    @echo "Tofu applied and IPs exported"

# ── Deploy (deploy-rs) ────────────────────────────
# Uses deploy-rs for auto-rollback on failure.
# Usage: just deploy-vm or just deploy-vultr

deploy-vm:
    nix run .#deploy-rs -- .#minz-home-vm-0 --skip-checks

deploy-vultr:
    nix run .#deploy-rs -- .#minz-vultr-nix-0 --skip-checks

deploy-all:
    nix run .#deploy-rs -- . --skip-checks
