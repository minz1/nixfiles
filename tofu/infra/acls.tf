# Existing bridge (imported once); only the ACL default actions are managed here.
resource "incus_network" "incusbr0" {
  name = "incusbr0"
  config = {
    "security.acls.default.egress.action"  = "reject"
    "security.acls.default.ingress.action" = "reject"
    # network-level logged is a verified no-op on Incus 7.0.1; use the NIC-device override in vms.tf instead
  }
}

locals {
  incus_bridge_subnet = "10.10.0.0/24"
  mgmt_subnet         = "10.8.0.0/24"
  edge_subnet         = "10.9.0.0/24"
  authentik_ip        = "10.10.0.3"
  desktop_ip          = "10.8.0.4"

  # Shared ingress rules: SSH, ACME HTTP-01, node_exporter. Source empty = any.
  common_ingress = [
    {
      action           = "allow"
      destination_port = "22"
      protocol         = "tcp"
      description      = "SSH"
      state            = "enabled"
    },
    {
      action           = "allow"
      destination_port = "80"
      protocol         = "tcp"
      description      = "ACME HTTP-01 challenge"
      state            = "enabled"
    },
    {
      action           = "allow"
      destination_port = "9100"
      protocol         = "tcp"
      description      = "Prometheus node_exporter"
      state            = "enabled"
    },
    {
      action           = "reject"
      protocol         = "udp"
      destination      = "224.0.0.251"
      destination_port = "5353"
      description      = "Suppress media-0 mDNS multicast (unlogged)"
      state            = "enabled"
    },
    {
      action      = "reject"
      protocol    = "icmp6"
      icmp_type   = "143"
      description = "Suppress MLDv2 multicast listener reports (unlogged)"
      state       = "enabled"
    },
  ]

  # Shared egress rules: bridge-internal traffic, plus each guest's own outbound MLDv2 report (which hits its egress list, not ingress).
  common_egress = [
    {
      action      = "allow"
      destination = local.incus_bridge_subnet
      description = "Bridge-internal traffic"
      state       = "enabled"
    },
    {
      action      = "reject"
      protocol    = "icmp6"
      icmp_type   = "143"
      description = "Suppress MLDv2 multicast listener reports (unlogged)"
      state       = "enabled"
    },
  ]

  vm_acl_map = {
    "minz-pki-0"       = incus_network_acl.pki.name
    "minz-obs-0"       = incus_network_acl.obs.name
    "minz-authentik-0" = incus_network_acl.authentik.name
    "minz-services-0"  = incus_network_acl.services.name
    "minz-game-0"      = incus_network_acl.game.name
    "minz-attic-0"     = incus_network_acl.attic.name
    "minz-runner-0"    = incus_network_acl.runner.name
  }

  container_acl_map = {
    "minz-media-0" = incus_network_acl.media.name
  }

  services_ip = "10.10.0.6"

  # IPv4 minus private/reserved ranges (0/8, 10/8, 100.64/10, 127/8, 169.254/16, 172.16/12,
  # 192.168/16, 224/4, 240/4). Incus evaluates reject before allow, so "internet but not internal"
  # has to be an allow-list. Generated with Python's ipaddress.address_exclude.
  public_ipv4 = [
    "1.0.0.0/8",
    "2.0.0.0/7",
    "4.0.0.0/6",
    "8.0.0.0/7",
    "11.0.0.0/8",
    "12.0.0.0/6",
    "16.0.0.0/4",
    "32.0.0.0/3",
    "64.0.0.0/3",
    "96.0.0.0/6",
    "100.0.0.0/10",
    "100.128.0.0/9",
    "101.0.0.0/8",
    "102.0.0.0/7",
    "104.0.0.0/5",
    "112.0.0.0/5",
    "120.0.0.0/6",
    "124.0.0.0/7",
    "126.0.0.0/8",
    "128.0.0.0/3",
    "160.0.0.0/5",
    "168.0.0.0/8",
    "169.0.0.0/9",
    "169.128.0.0/10",
    "169.192.0.0/11",
    "169.224.0.0/12",
    "169.240.0.0/13",
    "169.248.0.0/14",
    "169.252.0.0/15",
    "169.255.0.0/16",
    "170.0.0.0/7",
    "172.0.0.0/12",
    "172.32.0.0/11",
    "172.64.0.0/10",
    "172.128.0.0/9",
    "173.0.0.0/8",
    "174.0.0.0/7",
    "176.0.0.0/4",
    "192.0.0.0/9",
    "192.128.0.0/11",
    "192.160.0.0/13",
    "192.169.0.0/16",
    "192.170.0.0/15",
    "192.172.0.0/14",
    "192.176.0.0/12",
    "192.192.0.0/10",
    "193.0.0.0/8",
    "194.0.0.0/7",
    "196.0.0.0/6",
    "200.0.0.0/5",
    "208.0.0.0/4",
  ]
}

# pki-0: bridge egress + HTTP-01 validation to WG hosts on port 80.
resource "incus_network_acl" "pki" {
  name        = "pki"
  description = "minz-pki-0: bridge-internal egress + HTTP-01 to WG hosts"

  ingress = concat(local.common_ingress, [
    {
      action           = "allow"
      destination_port = "9443"
      protocol         = "tcp"
      description      = "step-ca ACME directory"
      state            = "enabled"
    },
  ])

  egress = concat(local.common_egress, [
    {
      action           = "allow"
      destination      = local.mgmt_subnet
      destination_port = "80"
      protocol         = "tcp"
      description      = "HTTP-01 ACME validation to WG hosts"
      state            = "enabled"
    },
    {
      action           = "allow"
      destination      = local.mgmt_subnet
      destination_port = "9000"
      protocol         = "tcp"
      description      = "S6: restic backups to RustFS on vultr-nix-0"
      state            = "enabled"
    },
  ])
}

# services-0: serves ntfy HTTPS; media-fixer needs HTTPS egress to Discord and LLM APIs.
resource "incus_network_acl" "services" {
  name        = "services"
  description = "minz-services-0: bridge-internal egress + HTTPS for media-fixer"

  ingress = concat(local.common_ingress, [
    {
      action           = "allow"
      destination_port = "443"
      protocol         = "tcp"
      description      = "Caddy HTTPS"
      state            = "enabled"
    },
  ])

  egress = concat(local.common_egress, [
    {
      action           = "allow"
      destination      = "0.0.0.0/0"
      destination_port = "443"
      protocol         = "tcp"
      description      = "HTTPS egress for Discord and LLM APIs (media-fixer)"
      state            = "enabled"
    },
    {
      action           = "allow"
      destination      = local.mgmt_subnet
      destination_port = "9000"
      protocol         = "tcp"
      description      = "S6: restic backups to RustFS on vultr-nix-0"
      state            = "enabled"
    },
  ])
}

# obs-0: bridge egress + node_exporter scraping of WG hosts.
resource "incus_network_acl" "obs" {
  name        = "obs"
  description = "minz-obs-0: bridge-internal egress + node_exporter scraping of WG hosts"

  ingress = concat(local.common_ingress, [
    {
      action           = "allow"
      source           = local.edge_subnet
      destination_port = "3443"
      protocol         = "tcp"
      description      = "Grafana HTTPS+mTLS (proxied by edge Caddy)"
      state            = "enabled"
    },
    {
      action           = "allow"
      destination_port = "3101"
      protocol         = "tcp"
      description      = "Loki HTTPS push from fleet Alloy agents"
      state            = "enabled"
    },
  ])

  egress = concat(local.common_egress, [
    {
      action           = "allow"
      destination      = local.mgmt_subnet
      destination_port = "9100"
      protocol         = "tcp"
      description      = "node_exporter scraping of WG hosts"
      state            = "enabled"
    },
    {
      action           = "allow"
      destination      = "0.0.0.0/0"
      destination_port = "443"
      protocol         = "tcp"
      description      = "HTTPS egress for Grafana dashboard imports"
      state            = "enabled"
    },
    {
      action           = "allow"
      destination      = "0.0.0.0/0"
      destination_port = "587"
      protocol         = "tcp"
      description      = "SMTP egress for Grafana alert email via Resend"
      state            = "enabled"
    },
  ])
}

# game-0: ATM10 Minecraft server + RCON for whitelist sync from edge.
resource "incus_network_acl" "game" {
  name        = "game"
  description = "minz-game-0: Minecraft + RCON from edge; 443 egress"

  ingress = concat(local.common_ingress, [
    {
      action           = "allow"
      source           = local.edge_subnet
      destination_port = "25565"
      protocol         = "tcp"
      description      = "Minecraft from Velocity (wg1 edge)"
      state            = "enabled"
    },
    {
      action           = "allow"
      source           = local.mgmt_subnet
      destination_port = "25565"
      protocol         = "tcp"
      description      = "Minecraft direct access from mgmt WireGuard"
      state            = "enabled"
    },
    {
      action           = "allow"
      source           = local.mgmt_subnet
      destination_port = "25575"
      protocol         = "tcp"
      description      = "RCON admin access from mgmt WireGuard"
      state            = "enabled"
    },
    {
      action           = "allow"
      source           = local.authentik_ip
      destination_port = "443"
      protocol         = "tcp"
      description      = "whitelist-sync webhook from Authentik"
      state            = "enabled"
    },
  ])

  egress = concat(local.common_egress, [
    {
      action           = "allow"
      protocol         = "tcp"
      destination_port = "443"
      description      = "HTTPS egress via Caddy forward proxy (allowlisted hosts only)"
      state            = "enabled"
    },
    {
      # unlogged reject, matched before the logged default — ~215k/day of Minecraft LAN discovery noise
      action           = "reject"
      protocol         = "udp"
      destination_port = "4445"
      description      = "Suppress Minecraft LAN discovery multicast (unlogged)"
      state            = "enabled"
    },
    {
      action           = "allow"
      destination      = local.mgmt_subnet
      destination_port = "9000"
      protocol         = "tcp"
      description      = "S6: restic backups to RustFS on vultr-nix-0"
      state            = "enabled"
    },
  ])
}

# runner-0: CI job runner — needs real internet (nix builds, gitleaks) plus Forgejo's API on mgmt.
resource "incus_network_acl" "runner" {
  name        = "runner"
  description = "minz-runner-0: bridge-internal egress + Forgejo API + full HTTP/HTTPS egress for nix builds and apt"

  ingress = local.common_ingress

  egress = concat(local.common_egress, [
    {
      action           = "allow"
      destination      = local.mgmt_subnet
      destination_port = "3000"
      protocol         = "tcp"
      description      = "Forgejo API (job reporting, task polling)"
      state            = "enabled"
    },
    {
      action           = "allow"
      destination      = "0.0.0.0/0"
      destination_port = "443"
      protocol         = "tcp"
      description      = "HTTPS egress for nix builds (cache.nixos.org) and CI tool fetches"
      state            = "enabled"
    },
    {
      action           = "allow"
      destination      = "0.0.0.0/0"
      destination_port = "80"
      protocol         = "tcp"
      description      = "HTTP egress for apt (Ubuntu's default archive mirrors)"
      state            = "enabled"
    },
  ])
}

# attic-0: serves HTTPS binary cache to the bridge only; no external egress needed.
resource "incus_network_acl" "attic" {
  name        = "attic"
  description = "minz-attic-0: bridge-internal only — HTTPS cache ingress, no external egress"

  ingress = concat(local.common_ingress, [
    {
      action           = "allow"
      destination_port = "443"
      protocol         = "tcp"
      description      = "Caddy HTTPS (Attic cache)"
      state            = "enabled"
    },
  ])

  egress = concat(local.common_egress, [
  ])
}

# authentik-0: serves HTTPS (OIDC/forward-auth) and LDAPS; sends SMTP via Resend.
resource "incus_network_acl" "authentik" {
  name        = "authentik"
  description = "minz-authentik-0: bridge-internal egress + SMTP for email"

  ingress = concat(local.common_ingress, [
    {
      action           = "allow"
      destination_port = "9443"
      protocol         = "tcp"
      description      = "Authentik HTTPS"
      state            = "enabled"
    },
    {
      action           = "allow"
      destination_port = "6636"
      protocol         = "tcp"
      description      = "Authentik LDAPS"
      state            = "enabled"
    },
  ])

  egress = concat(local.common_egress, [
    {
      action           = "allow"
      destination      = "0.0.0.0/0,::/0"
      destination_port = "443"
      protocol         = "tcp"
      description      = "HTTPS egress for external APIs (Mojang UUID lookup, OAuth JWKS)"
      state            = "enabled"
    },
    {
      action           = "allow"
      destination      = "0.0.0.0/0,::/0"
      destination_port = "465,587"
      protocol         = "tcp"
      description      = "SMTP egress for Resend email delivery"
      state            = "enabled"
    },
    {
      action           = "allow"
      destination      = local.mgmt_subnet
      destination_port = "9000"
      protocol         = "tcp"
      description      = "S6: restic backups to RustFS on vultr-nix-0"
      state            = "enabled"
    },
  ])
}

# media-0: broad internet egress (debrid, indexers, metadata) but no reach into the fleet beyond
# the bridge and RustFS; app ports only from media-fixer on services-0, everything else via Caddy.
resource "incus_network_acl" "media" {
  name        = "media"
  description = "minz-media-0: internet egress + Caddy ingress; app ports from services-0 only"

  ingress = concat(local.common_ingress, [
    {
      action           = "allow"
      destination_port = "443"
      protocol         = "tcp"
      description      = "Caddy HTTPS"
      state            = "enabled"
    },
    {
      action           = "allow"
      source           = local.services_ip
      destination_port = "7878,8096,8282,8989,9191"
      protocol         = "tcp"
      description      = "media-fixer on services-0: radarr, jellyfin, decypharr, sonarr, media-agent"
      state            = "enabled"
    },
    {
      action           = "allow"
      source           = local.desktop_ip
      destination_port = "8443"
      protocol         = "tcp"
      description      = "decypharr UI via Caddy, desktop over WireGuard only"
      state            = "enabled"
    },
  ])

  egress = concat(local.common_egress, [
    {
      action           = "allow"
      destination      = local.mgmt_subnet
      destination_port = "9000"
      protocol         = "tcp"
      description      = "restic backups to RustFS on vultr-nix-0"
      state            = "enabled"
    },
    {
      action      = "allow"
      destination = join(",", local.public_ipv4)
      description = "Public IPv4 internet"
      state       = "enabled"
    },
    {
      action      = "allow"
      destination = "2000::/3"
      description = "Public IPv6 internet"
      state       = "enabled"
    },
  ])
}
