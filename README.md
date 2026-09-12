# nixfiles

## Hosts

| Host | Role | Network |
|------|------|---------|
| `minz-vultr-nix-0` | WireGuard hub, Forgejo + Postgres, RustFS (S3 state backend) | `10.8.0.1` |
| `minz-vultr-nix-1` | Edge ingress — Caddy + CrowdSec + Velocity (Minecraft proxy) | `10.8.0.6` / `10.9.0.1` |
| `minz-home-nix-0` | Bare metal, Incus host | `10.8.0.5` / `10.10.0.1` |
| `minz-obs-0` | VictoriaMetrics, Loki, Grafana; Alloy fleet-wide log/metric shipping | `10.10.0.2` |
| `minz-authentik-0` | Authentik SSO + LDAP outpost | `10.10.0.3` |
| `minz-media-0` | Jellyfin, Seerr, Sonarr, Radarr, Prowlarr, Bazarr, Decypharr, media-agent | `10.10.0.7` |
| `minz-services-0` | ntfy, media-fixer | `10.10.0.6` |
| `minz-pki-0` | step-ca internal CA (ACME + mTLS client cert issuance) | `10.10.0.8` |
| `minz-game-0` | ATM10 Minecraft server (rootless Podman, oci user) | `10.10.0.9` |
| `minz-attic-0` | Attic binary cache (CI push target, fleet substituter) | `10.10.0.12` |
| `minz-runner-0` | Forgejo Actions runner (rootless Podman job containers) | `10.10.0.13` |

Incus VMs/containers run on `minz-home-nix-0` bridged at `10.10.0.0/24`.

## Usage

```bash
nix develop                          # enter dev shell

just deploy node <host>              # deploy one host
just deploy all                      # deploy all hosts
just deploy phased                   # deploy in dependency order

just admin check                     # flake check + fmt + shellcheck
just admin update                    # bump flake.lock, build every host closure
just admin health                    # fleet-wide failed-unit / crash-loop check

just tofu infra-plan                 # plan Incus VM lifecycle
just tofu infra-apply
just tofu app-plan                   # plan app config (Authentik, DNS, etc.)
just tofu app-apply
```

CI (Forgejo Actions, `minz-runner-0`) builds affected hosts and pushes to Attic on every
push — see `just ci` and `.forgejo/workflows/`. It has no deploy authority; deploys are
always run by a human from the desktop.

## Structure

```
common/     topology, SSH keys, WireGuard
hosts/      per-host NixOS configurations
modules/    reusable NixOS modules (profiles, services, hardening)
pkgs/       custom package overlays
scripts/    shell scripts backing justfile recipes
just/       justfile submodules (admin, bootstrap, ci, deploy, tofu)
secrets/    sops-encrypted secrets (per-host + shared)
tofu/       OpenTofu — infra/ (Incus VMs) and app/ (Authentik, arr stack)
```

## Secrets

Each host decrypts its own secrets using its SSH ed25519 host key as an age identity. New host ceremony:

```bash
just bootstrap keygen <host>      # generate SSH host key in RAM, print age pubkey
# add age pubkey to .sops.yaml, then:
just bootstrap store-key <host>   # encrypt key into secrets/<host>.yaml
just bootstrap install-vm <host>  # provision via nixos-anywhere (VMs)
just deploy node <host>
```
