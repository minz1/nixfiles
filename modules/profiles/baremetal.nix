{ lib, hostName, ... }:

let
  topology = import ../../common/topology.nix;
  node = topology.nodes.${hostName} or (throw "No topology entry for ${hostName}");
  disk = node.storage.disk;
  nixSize = node.storage.nix_size or "30G";
in
{
  boot.initrd.availableKernelModules = [
    "ata_piix"
    "uhci_hcd"
    "ahci"
    "xhci_pci"
    "virtio_pci"
    "virtio_scsi"
    "virtio_blk"
    "sd_mod"
    "sr_mod"
  ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  networking.useDHCP = lib.mkDefault true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault false;

  fileSystems."/" = {
    device = "none";
    fsType = "tmpfs";
    options = [
      "defaults"
      "size=2G"
      "mode=755"
    ];
  };

  fileSystems."/nix".neededForBoot = true;
  fileSystems."/persist".neededForBoot = true;

  disko.devices.disk.main = {
    device = disk;
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        nix = {
          size = nixSize;
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/nix";
          };
        };
        persist = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/persist";
          };
        };
      };
    };
  };
}
