{ lib, ... }:

# Minimal placeholder for Lenovo ThinkCentre M70s (i7-10700).
# This file is overwritten by nixos-generate-config during `just bootstrap install`.
{
  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "ahci"
    "usb_storage"
    "sd_mod"
    "usbhid"
  ];
  boot.kernelModules = [ "kvm-intel" ];
  hardware.cpu.intel.updateMicrocode = lib.mkDefault true;
}
