{ lib, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/virtualisation/incus-virtual-machine.nix")
    ../nixos/common.nix
  ];

  boot.initrd.availableKernelModules = [
    "ata_piix"
    "uhci_hcd"
    "virtio_pci"
    "virtio_scsi"
    "sd_mod"
    "sr_mod"
  ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  virtualisation.incus.agent.enable = true;

  services.qemuGuest.enable = true;
  services.spice-vdagentd.enable = true;

  networking.hostName = lib.mkDefault "nixos-bootstrap";

  networking.useDHCP = false;
  systemd.network.enable = true;
  systemd.network.networks."10-eth0" = {
    matchConfig.Name = "en*";
    networkConfig.DHCP = "ipv4";
    linkConfig.RequiredForOnline = "routable";
  };

  services.xserver.enable = false;

  system.stateVersion = "25.11";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = false;
}
