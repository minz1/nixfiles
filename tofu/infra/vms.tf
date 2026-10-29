# The checked fleet data (`nix eval --json .#fleet`); the `just tofu` recipes set TF_VAR_fleet.
variable "fleet" {
  type = any
}

locals {
  all_nodes = var.fleet.nodes

  all_vms = {
    for name, node in local.all_nodes : name => node
    if contains(["incus-vm", "incus-container"], node.kind)
  }

  nixos_vms = {
    for name, node in local.all_vms : name => node
    if node.kind == "incus-vm"
  }

  nixos_containers = {
    for name, node in local.all_vms : name => node
    if node.kind == "incus-container"
  }
}

# --- NixOS VMs ---

resource "incus_instance" "vm" {
  for_each = local.nixos_vms

  name  = each.key
  image = "nixos-bootstrap" # stable alias — incus_image.bootstrap.fingerprint would force-replace on every republish
  type  = "virtual-machine"

  depends_on = [incus_image.bootstrap]

  config = {
    "limits.cpu"          = tostring(each.value.incus.cpus)
    "limits.memory"       = "${each.value.incus.memory_gib}GiB"
    "security.secureboot" = true
  }

  device {
    name = "eth0"
    type = "nic"
    properties = merge(
      {
        network        = local.incus_bridge_name
        "ipv4.address" = each.value.networks.incus_bridge.ip
        # a guest that can spoof another's MAC/IP can answer its HTTP-01 challenge and mint its cert
        "security.mac_filtering"  = "true"
        "security.ipv4_filtering" = "true"
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
    "limits.memory"    = "${each.value.incus.memory_gib}GiB"
    "security.nesting" = each.value.incus.nesting
  }

  device {
    name = "eth0"
    type = "nic"
    properties = merge(
      {
        network        = local.incus_bridge_name
        "ipv4.address" = each.value.networks.incus_bridge.ip
        # a guest that can spoof another's MAC/IP can answer its HTTP-01 challenge and mint its cert
        "security.mac_filtering"  = "true"
        "security.ipv4_filtering" = "true"
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
      size = "${each.value.incus.root_gib}GiB"
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
    for_each = each.value.incus.gpu ? [1] : []
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

  # a new bootstrap image fingerprint must never force-replace an existing container
  lifecycle {
    ignore_changes = [image]
  }
}

locals {
  incus_bridge_name = "incusbr0"
}
