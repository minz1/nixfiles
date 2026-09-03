variable "hostname" {
  type        = string
  default     = ""
  description = "Specific VM hostname to target. Empty string targets all Incus VMs."
}

# Nix eval wraps the result in a JSON string so Tofu doesn't try to parse nested Nix types.
data "external" "topology" {
  program = [
    "nix", "eval", "--json", "--impure",
    "--expr",
    "let nodes = import ../../common/topology.nix; keys = import ../../common/ssh-keys.nix; in { data = builtins.toJSON { inherit (nodes) nodes; sshKeys = keys.minz1; }; }",
  ]
}

locals {
  # Decode the string-encoded JSON back into a Tofu map.
  all_data  = jsondecode(data.external.topology.result.data)
  all_nodes = local.all_data.nodes
  ssh_keys  = local.all_data.sshKeys

  all_vms = {
    for name, node in local.all_nodes : name => node
    if try(node.provisioner, "") == "incus"
  }

  vms = var.hostname != "" ? {
    for k, v in local.all_vms : k => v if k == var.hostname
  } : local.all_vms

  nixos_vms = {
    for name, node in local.vms : name => node
    if try(node.os, "") == "nixos" && try(node.incus.incus_type, "virtual-machine") != "container"
  }

  nixos_containers = {
    for name, node in local.vms : name => node
    if try(node.os, "") == "nixos" && try(node.incus.incus_type, "virtual-machine") == "container"
  }

  other_vms = {
    for name, node in local.vms : name => node
    if try(node.os, "") != "nixos"
  }
}

# --- NixOS VMs ---

resource "incus_instance" "vm" {
  for_each = local.nixos_vms

  name  = each.key
  image = incus_image.bootstrap.fingerprint
  type  = "virtual-machine"

  config = {
    "limits.cpu"    = tostring(each.value.incus.cpus)
    "limits.memory" = each.value.incus.memory
    "security.secureboot" = true
  }

  device {
    name = "eth0"
    type = "nic"
    properties = merge(
      {
        network        = local.incus_bridge_name
        "ipv4.address" = each.value.networks.incus_bridge.ip
      },
      lookup(local.vm_acl_map, each.key, "") != "" ? {
        "security.acls" = lookup(local.vm_acl_map, each.key, "")
        # NIC-device override, not network-level (that's a documented no-op on this Incus build)
        "security.acls.default.ingress.logged" = "true"
        "security.acls.default.egress.logged"  = "true"
      } : {}
    )
  }

  device {
    name = "root"
    type = "disk"
    properties = {
      path = "/"
      pool = "default"
      size = "10GiB"
    }
  }

  device {
    name = "persist"
    type = "disk"
    properties = {
      source = incus_storage_volume.persist[each.key].name
      pool   = "default"
    }
  }

}

# --- NixOS containers ---

data "sops_file" "container_host_keys" {
  for_each    = local.nixos_containers
  source_file = "${path.root}/../../secrets/${each.key}.yaml"
}

resource "incus_instance" "container" {
  for_each = local.nixos_containers

  name  = each.key
  image = incus_image.bootstrap_container.fingerprint
  type  = "container"

  config = {
    "limits.cpu"       = tostring(each.value.incus.cpus)
    "limits.memory"    = each.value.incus.memory
    "security.nesting" = try(each.value.incus.nesting, false)
  }

  device {
    name = "eth0"
    type = "nic"
    properties = merge(
      {
        network        = local.incus_bridge_name
        "ipv4.address" = each.value.networks.incus_bridge.ip
      },
      lookup(local.container_acl_map, each.key, "") != "" ? {
        "security.acls" = lookup(local.container_acl_map, each.key, "")
      } : {}
    )
  }

  device {
    name = "root"
    type = "disk"
    properties = {
      path = "/"
      pool = "default"
      size = try(each.value.incus.root_size, "60GiB")
    }
  }

  dynamic "device" {
    for_each = each.key == "minz-media-0" ? [1] : []
    content {
      name = "cache"
      type = "disk"
      properties = {
        source = incus_storage_volume.media_cache.name
        pool   = "default"
        path   = "/var/cache/decypharr"
      }
    }
  }

  # GPU DRM passthrough via cgroup device allowlisting — no VFIO/IOMMU required.
  dynamic "device" {
    for_each = try(each.value.incus.gpu, false) ? [1] : []
    content {
      name = "gpu"
      type = "gpu"
      properties = {
        gputype = "physical"
      }
    }
  }

  wait_for {
    type = "ipv4"
  }

  # Inject the SSH host key so sops-nix can decrypt secrets on first deploy-rs activation.
  file {
    content            = data.sops_file.container_host_keys[each.key].data["ssh_host_ed25519_key"]
    target_path        = "/etc/ssh/ssh_host_ed25519_key"
    uid                = 0
    gid                = 0
    mode               = "0600"
    create_directories = true
  }

  exec = {
    # Derive pubkey and restart sshd; exec blocks run in key order after file uploads.
    "00-derive-pubkey" = {
      command = ["/bin/sh", "-c", "ssh-keygen -y -f /etc/ssh/ssh_host_ed25519_key > /etc/ssh/ssh_host_ed25519_key.pub && chmod 644 /etc/ssh/ssh_host_ed25519_key.pub"]
      trigger = "once"
    }
    "01-restart-sshd" = {
      command = ["/run/current-system/sw/bin/systemctl", "restart", "sshd"]
      trigger = "once"
    }
  }
}

# --- Non-NixOS VMs ---

resource "incus_instance" "other_vm" {
  for_each = local.other_vms

  name  = each.key
  image = each.value.incus.image
  type  = "virtual-machine"

  config = {
    "limits.cpu"    = tostring(each.value.incus.cpus)
    "limits.memory" = each.value.incus.memory
    "security.secureboot" = false
    # Cloud-Init user data for SSH key injection and static IP.
    "user.user-data" = templatefile("${path.module}/cloud-init.yaml.tftpl", {
      hostname     = each.key
      ssh_keys     = local.ssh_keys
      ip           = each.value.networks.incus_bridge.ip
      gateway      = local.gateway_ip
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

  device {
    name = "root"
    type = "disk"
    properties = {
      path = "/"
      pool = "default"
      size = "20GiB"
    }
  }
}

locals {
  # The Incus gateway is the node with provisioner == "incus-host".
  host_node = one([
    for name, node in local.all_nodes : node
    if try(node.provisioner, "") == "incus-host"
  ])

  gateway_ip        = local.host_node.networks.incus_bridge.ip
  incus_bridge_name = "incusbr0"
  incus_prefix      = 24
}
