# Outputs
#
# IPs flow from common/topology.nix → OpenTofu (not the other way around).
# These outputs provide visibility after `tofu apply`.

output "vms" {
  description = "Status of all Incus VMs managed by OpenTofu"
  value = {
    for name, inst in incus_instance.vm : name => {
      name    = inst.name
      status  = inst.status
      image   = inst.image
    }
  }
}
