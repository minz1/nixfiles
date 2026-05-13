# VM definitions
# When adding a new VM, pick the next free IP from incusbr0 (10.10.0.0/24)
# and add it to common/vm-ips.nix.
#
# Convention: minz-vm-<os>-<number>

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
#     }
#   }
# }
