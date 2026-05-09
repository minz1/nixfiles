# nixfiles

minz1's Nixfiles

## Hosts

| Host | Role | Address |
|------|------|---------|
| `minz-vultr-nix-0` | Bootstrap VPS | `10.8.0.1` |
| `minz-home-vm-0` | Local VM | `10.8.0.5` |

## Deployment

```bash
nixos-rebuild (test/deploy) \
  --flake .#<hostname> \
  --target-host <user>@<host> \
  --sudo \
  --ask-sudo-password
```

## Structure

```
nixfiles/
├── common/           # Shared data (SSH keys, WireGuard topology)
├── hosts/            # Per-host configs
├── modules/          # Reusable NixOS modules
│   ├── base.nix      # Shared baseline for all hosts
│   └── services/     # Service modules (decypharr)
└── pkgs/             # Custom package overlays
```

## Secrets
| Path | Description |
|------|-------------|
| `/var/lib/wireguard/private` | WireGuard private key (`wg genkey`, mode `0400`) |
| `/var/lib/secrets/forgejo-runner/token` | Forgejo runner registration token (mode `0400`) |
