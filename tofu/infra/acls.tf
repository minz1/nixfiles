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
  }
}

locals {
  incus_bridge_subnet = "10.10.0.0/24"
  mgmt_subnet         = "10.8.0.0/24"

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
  }

  container_acl_map = {
    "minz-services-0" = incus_network_acl.services.name
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

# services-0: serves Memos HTTPS; no external egress needed.
resource "incus_network_acl" "services" {
  name        = "services"
  description = "minz-services-0: bridge-internal egress only"

  ingress = concat(local.common_ingress, [
    {
      action           = "allow"
      destination_port = "443"
      protocol         = "tcp"
      description      = "Caddy HTTPS"
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
      description      = "Prometheus node_exporter scraping of WG hosts"
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
      destination_port = "465,587"
      protocol         = "tcp"
      description      = "SMTP egress for Resend email delivery"
      state            = "enabled"
    },
  ]
}
