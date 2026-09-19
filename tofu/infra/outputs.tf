output "vms" {
  description = "Status of all Incus NixOS VMs managed by OpenTofu"
  value = {
    for name, inst in incus_instance.vm : name => {
      name   = inst.name
      status = inst.status
      image  = inst.image
    }
  }
}
