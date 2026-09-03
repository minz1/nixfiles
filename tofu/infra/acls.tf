# Import existing bridge to set ACL default actions; computed keys are left untouched.
import {
  to = incus_network.incusbr0
  id = "incusbr0"
}

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
  ]

  vm_acl_map = {
    "minz-pki-0"       = incus_network_acl.pki.name
    "minz-obs-0"       = incus_network_acl.obs.name
    "minz-authentik-0" = incus_network_acl.authentik.name
    "minz-services-0"  = incus_network_acl.services.name
    "minz-game-0"      = incus_network_acl.game.name
  }

  container_acl_map = {
    # minz-media-0: no ACL — broad internet egress required (debrid, indexers)
  }
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

  egress = [
    {
      action      = "allow"
      destination = local.incus_bridge_subnet
      description = "Bridge-internal traffic"
      state       = "enabled"
    },
    {
      action           = "allow"
      destination      = local.mgmt_subnet
      destination_port = "80"
      protocol         = "tcp"
      description      = "HTTP-01 ACME validation to WG hosts"
      state            = "enabled"
    },
  ]
}

# services-0: serves Memos HTTPS; media-fixer needs HTTPS egress to Discord and LLM APIs.
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
    {
      action           = "allow"
      source           = local.mgmt_subnet
      destination_port = "8081"
      protocol         = "tcp"
      description      = "media-fixer dashboard from WireGuard mgmt"
      state            = "enabled"
    },
    {
      action           = "allow"
      source           = local.edge_subnet
      destination_port = "8081"
      protocol         = "tcp"
      description      = "media-fixer dashboard from WireGuard edge (admin.minz1.com via vultr-nix-1)"
      state            = "enabled"
    },
  ])

  egress = [
    {
      action      = "allow"
      destination = local.incus_bridge_subnet
      description = "Bridge-internal traffic"
      state       = "enabled"
    },
    {
      action           = "allow"
      destination      = "0.0.0.0/0"
      destination_port = "443"
      protocol         = "tcp"
      description      = "HTTPS egress for Discord and LLM APIs (media-fixer)"
      state            = "enabled"
    },
  ]
}

# obs-0: bridge egress + node_exporter scraping of WG hosts.
resource "incus_network_acl" "obs" {
  name        = "obs"
  description = "minz-obs-0: bridge-internal egress + node_exporter scraping of WG hosts"

  ingress = concat(local.common_ingress, [
    {
      action           = "allow"
      destination_port = "3000"
      protocol         = "tcp"
      description      = "Grafana (proxied by edge Caddy)"
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

  egress = [
    {
      action      = "allow"
      destination = local.incus_bridge_subnet
      description = "Bridge-internal traffic"
      state       = "enabled"
    },
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
  ]
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
      source           = local.edge_subnet
      destination_port = "25575"
      protocol         = "tcp"
      description      = "RCON from whitelist sync on vultr-nix-1 (wg1 edge)"
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
  ])

  egress = [
    {
      action      = "allow"
      destination = local.incus_bridge_subnet
      description = "Bridge-internal traffic"
      state       = "enabled"
    },
    {
      action           = "allow"
      protocol         = "tcp"
      destination_port = "443"
      description      = "CurseForge / CDN — modpack install and updates"
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
  ]
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

  egress = [
    {
      action      = "allow"
      destination = local.incus_bridge_subnet
      description = "Bridge-internal traffic"
      state       = "enabled"
    },
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
  ]
}
