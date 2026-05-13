# Outputs for the flake to consume
# After `tofu apply`, run the export script to regenerate common/vm-ips.nix:
#
#   tofu output | sort | perl -ne '
#     chomp;
#     s/_/./g;
#     print "  $_;\n"
#   ' > ../common/vm-ips.nix

# output "minz_vm_ubuntu_0_ipv4" {
#   value = incus_instance.ubuntu_0.ipv4_address
# }
