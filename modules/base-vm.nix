{
  hostName,
  ...
}:

let
  topology = import ../common/topology.nix;
  node = topology.nodes.${hostName} or (throw "No topology entry for ${hostName}");
  vmIp = node.networks.incus_bridge.ip;
in
{
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
  systemd.services.sshd.after = [ ];
  systemd.services.sshd.wants = [ ];

  networking.firewall.allowedTCPPorts = [ 22 ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = false;

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
          root = {
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
        };
      };
    };
    disk.persist = {
      device = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_incus_persist";
      content = {
        type = "filesystem";
        format = "ext4";
        mountpoint = "/persist";
      };
    };
  };
}
