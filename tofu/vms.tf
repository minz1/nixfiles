# VM definitions
#
# IPs and specs are the source of truth in common/topology.nix.
# Add a new VM there first, then uncomment/add a resource block here.
#
# Convention: minz-vm-<os>-<number>
# IPs:        10.10.0.0/24 (incus_bridge), starting at .10

# resource "incus_instance" "ubuntu_0" {
#   name  = "minz-vm-ubuntu-0"
#   image = "images:ubuntu/24.04"
#   type  = "virtual-machine"
#
#   config = {
#     "limits.cpu"    = "2"
#     "limits.memory" = "4GiB"
#   }
#
#   device {
#     name = "eth0"
#     type = "nic"
#     properties = {
#       network = "incusbr0"
#       # Static IP is assigned by cloud-init / preseed using the value
#       # defined in common/topology.nix nodes.minz-vm-ubuntu-0.networks.incus_bridge.ip
#     }
#   }
# }
