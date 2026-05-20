# nixfiles

minz1's NixOS infrastructure — declarative, sops-encrypted, deploy-rs deployed.

## Hosts

| Host | Role | Address |
|------|------|---------|
| `minz-vultr-nix-0` | VPN server, Forgejo, CI runner | `10.8.0.1` |
| `minz-home-vm-0` | Incus host, OpenTofu orchestrator | `10.8.0.5` |
| `minz-vm-nixos-0` | Incus VM — Decypharr | `10.10.0.11` |

## Deployment

```bash
# Deploy a single host
just deploy <hostname>

# Deploy all hosts
just deploy-all

# Provision / update Incus VMs via OpenTofu
just tofu-plan
just tofu-apply
```

## Structure

```
nixfiles/
├── common/           # Shared data (topology, SSH keys, WireGuard config)
├── docs/             # Architecture decisions and design notes
├── hosts/            # Per-host NixOS configurations
├── modules/          # Reusable NixOS modules
│   ├── common.nix    # Shared baseline (openssh, users, sudo, neovim)
│   ├── base.nix      # Live-host baseline (WireGuard, sops, firewall)
│   ├── base-vm.nix   # Incus VM baseline (networking, disk layout)
│   └── services/     # Service modules (decypharr, ...)
├── pkgs/             # Custom package overlays
├── secrets/          # sops-encrypted secret files
└── tofu/             # OpenTofu configurations (Incus VM lifecycle)
```

## Secrets management

This project uses [sops](https://github.com/getsops/sops) with [sops-nix](https://github.com/Mic92/sops-nix). Each host's SSH ed25519 host key is used as its age decryption identity — no separate key management required.

### Local setup

```bash
# Generate an age key from your local SSH key and export it for sops
mkdir -p ~/.config/sops/age
ssh-to-age -private-key -i ~/.ssh/id_ed25519 -o ~/.config/sops/age/keys.txt
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
```

### Adding a new host

1. Provision the machine
2. Grab its SSH host public key: `sudo cat /etc/ssh/ssh_host_ed25519_key.pub`
3. Convert to age: `ssh-to-age < host_key.pub`
4. Add the age key to `.sops.yaml` and run `sops updatekeys secrets/<host>.yaml`
5. `just deploy <hostname>`

### Secrets files

| File | Type | Description |
|------|------|-------------|
| `secrets/<host>.yaml` | sops-encrypted | Per-host secrets (WireGuard key, service tokens) |
| `secrets/incus-client.yaml` | sops-encrypted | Incus TLS client private key |
| `secrets/incus-client.crt` | plaintext | Incus TLS client certificate (public, safe to commit) |
| `secrets/rustfs-tofu.env` | sops-encrypted | RustFS S3 credentials for OpenTofu state backend |
