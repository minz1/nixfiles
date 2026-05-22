{
  hostName,
  lib,
  modulesPath,
  ...
}:

let
  topology = import ../../common/topology.nix;
  node = topology.nodes.${hostName} or (throw "No topology entry for ${hostName}");
  vmIp = node.networks.incus_bridge.ip;
  nixSize = node.incus.nix_size or "60GiB";
in
{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  networking.hostName = hostName;

  networking.useNetworkd = true;
  networking.useDHCP = false;

  systemd.network.networks."10-enp" = {
    matchConfig.Name = "en*";
    networkConfig.Address = [ "${vmIp}/24" ];
    networkConfig.Gateway = [ "10.10.0.1" ];
    linkConfig.RequiredForOnline = "routable";
  };

  services.openssh.listenAddresses = [
    {
      addr = "0.0.0.0";
      port = 22;
    }
  ];

  networking.firewall.allowedTCPPorts = [ 22 ];

  boot.initrd.availableKernelModules = [
    "ata_piix"
    "uhci_hcd"
    "virtio_pci"
    "virtio_scsi"
    "sd_mod"
    "sr_mod"
  ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = false;

  virtualisation.incus.agent.enable = true;

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

  disko.devices = {
    disk.root = {
      device = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_incus_root";
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
        };
      };
    };
    disk.persist = {
      device = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_incus_persist";
      content = {
        type = "gpt";
        partitions = {
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
  };
}
