output "vms" {
  description = "Status of all Incus NixOS VMs managed by OpenTofu"
  value = {
    for name, inst in incus_instance.vm : name => {
      name    = inst.name
      status  = inst.status
      image   = inst.image
    }
  }
}

output "other_vms" {
  description = "Status of all non-NixOS Incus VMs managed by OpenTofu"
  value = {
    for name, inst in incus_instance.other_vm : name => {
      name    = inst.name
      status  = inst.status
      image   = inst.image
    }
  }
}
