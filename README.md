# nixfiles

## Hosts

| Host | Role | Network |
|------|------|---------|
| `minz-vultr-nix-0` | WireGuard hub, Forgejo, CI runner, S3 state backend | `10.8.0.1` |
| `minz-vultr-nix-1` | Edge ingress (Caddy TLS termination) | `10.8.0.6` / `10.9.0.1` |
| `minz-home-nix-0` | Bare metal, Incus host | `10.8.0.5` / `10.10.0.1` |
| `minz-obs-0` | Prometheus, Loki, Grafana | `10.10.0.2` |
| `minz-authentik-0` | Authentik SSO + LDAP | `10.10.0.3` |
| `minz-arr-0` | Sonarr, Radarr, Prowlarr, Bazarr, Decypharr | `10.10.0.4` |
| `minz-jellyfin-0` | Jellyfin, Seerr | `10.10.0.5` |
| `minz-services-0` | ntfy, media-fixer | `10.10.0.6` |

Incus VMs/containers run on `minz-home-nix-0` bridged at `10.10.0.0/24`.

## Usage

```bash
nix develop                          # enter dev shell

just deploy node <host>              # deploy one host
just deploy all                      # deploy all hosts

just tofu infra-plan                 # plan Incus VM lifecycle
just tofu infra-apply
just tofu app-plan                   # plan app config (Authentik, DNS, etc.)
just tofu app-apply
```

## Structure

```
common/     topology, SSH keys
hosts/      per-host NixOS configurations
modules/    reusable NixOS modules (profiles, services)
pkgs/       custom package overlays
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
