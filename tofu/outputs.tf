# Outputs
#
# IPs flow from common/topology.nix → OpenTofu (not the other way around).
# Add VM outputs here for visibility after `tofu apply`, e.g.:
#
# output "minz_vm_ubuntu_0_state" {
#   value = incus_instance.ubuntu_0.status
# }
