# VM definitions
#
# IPs and specs are the source of truth in common/topology.nix.
# Add a new VM there first, then target it here.
#
# Convention: minz-vm-<os>-<number>
# IPs:        10.10.0.0/24 (incus_bridge), starting at .10

variable "hostname" {
  type        = string
  default     = ""
  description = "Specific VM hostname to target. Empty string targets all Incus VMs."
}

# Read all nodes from the Nix topology. The --apply transformation wraps the
# attribute set in a JSON string so Tofu doesn't try to parse nested Nix types.
data "external" "topology" {
  program = [
    "nix", "eval", "--json",
    "--apply", "nodes: { data = builtins.toJSON nodes; }",
    "-f", "../common/topology.nix",
    "nodes"
  ]
}

locals {
  # Decode the string-encoded JSON back into a Tofu map.
  all_nodes = jsondecode(data.external.topology.result.data)

  # Filter to nodes provisioned by Incus.
  all_vms = {
    for name, node in local.all_nodes : name => node
    if try(node.provisioner, "") == "incus"
  }

  # If a specific hostname was given, scope down to just that VM.
  vms = var.hostname != "" ? {
    for k, v in local.all_vms : k => v if k == var.hostname
  } : local.all_vms
}

# ── Incus VM resources ──────────────────────────────────────────────────────
# One instance per VM in the filtered map above.

resource "incus_instance" "vm" {
  for_each = local.vms

  name  = each.key
  image = each.value.incus.image
  type  = "virtual-machine"

  config = {
    "limits.cpu"    = tostring(each.value.incus.cpus)
    "limits.memory" = each.value.incus.memory
    "security.secureboot" = false
    # Cloud-Init user data for SSH key injection and static IP.
    # The NixOS Incus image (nixos-cloud-init-worker) reads this natively.
    "user.user-data" = templatefile("${path.module}/cloud-init.yaml.tftpl", {
      hostname     = each.key
      ssh_keys     = local.ssh_keys
      ip           = each.value.networks.incus_bridge.ip
      gateway      = local.gateway_ip
      # Derive the prefix length from the subnet definition in topology.
      prefix       = local.incus_prefix
    })
  }

  device {
    name = "eth0"
    type = "nic"
    properties = {
      network = local.incus_bridge_name
    }
  }
}

# ── Helper locals for network defaults ───────────────────────────────────────

locals {
  # The home VM acts as the gateway for the Incus bridge.
  # We find it by looking for the node with provisioner == "incus-host".
  host_node = one([
    for name, node in local.all_nodes : node
    if try(node.provisioner, "") == "incus-host"
  ])

  gateway_ip        = local.host_node.networks.incus_bridge.ip
  incus_bridge_name = "incusbr0"
  incus_prefix      = 24

  # SSH keys from the topology are already inline in the Nix expression;
  # however, Cloud-Init needs them explicitly. We read the static keys file.
  # This is a bit awkward in Tofu — we'll just hardcode minz1's key for now.
  # In a more advanced setup you'd pass this through the Nix external data source.
  ssh_keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHNoD5UnAh24jCiSTeS5i2WNsf7x45qYKtMEBVFVqm7C emerytang@gmail.com",
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOAk9gGizgwrnA0dtN6Fv5EvQ/OyGt+d6dbtJUZUAZjZ emerytang@gmail.com",
  ]
}
