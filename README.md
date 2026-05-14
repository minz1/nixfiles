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

## Secrets management

This project uses [SOPS](https://github.com/getsops/sops) with [sops-nix](https://github.com/Mic92/sops-nix). SSH host keys are used as age identities.

### Local setup

To edit secrets, you must point SOPS to an age-compatible private key. If your `~/.ssh/id_ed25519` is password-protected, generate a native age key file:

```bash
mkdir -p ~/.config/sops/age
ssh-to-age -private-key -i ~/.ssh/id_ed25519 -o ~/.config/sops/age/keys.txt
```

Then export the path in your shell or `.envrc`:

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
```

## Secrets
| Path | Description |
|------|-------------|
| `/var/lib/wireguard/private` | WireGuard private key (`wg genkey`, mode `0400`) |
| `/var/lib/secrets/forgejo-runner/token` | Forgejo runner registration token (mode `0400`) |
