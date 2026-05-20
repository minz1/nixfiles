{
  pkgs,
  lib,
  hostName,
  ...
}:

let
  topology = (import ../../common/topology.nix);

  node = topology.nodes."${hostName}";
  incusNetwork = topology.networks.incus_bridge;
  incusNodeNetwork = node.networks.incus_bridge;
  wgAddr = node.networks.mgmt.ip;

  incusPrefix = lib.last (lib.splitString "/" incusNetwork.subnet);
in
{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = hostName;
  system.stateVersion = "25.11";

  networking.networkmanager.enable = true;
  networking.nftables.enable = true;
  networking.firewall.trustedInterfaces = [ incusNetwork.interface ];

  services.openssh.listenAddresses = [
    {
      addr = wgAddr;
      port = node.services.ssh.port;
    }
  ];

  services.qemuGuest.enable = true;
  services.spice-vdagentd.enable = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelPackages = pkgs.linuxPackages_latest;

  users.users.minz1 = {
    description = "Minz One";
    extraGroups = [
      "networkmanager"
      "incus-admin"
    ];
  };

  programs.neovim.defaultEditor = true;
  environment.systemPackages = with pkgs; [
    opentofu
    sops
  ];

  environment.shellAliases = {
    vi = "nvim";
    vim = "nvim";
  };

  virtualisation.incus = {
    enable = true;
    preseed = {
      config = {
        "core.https_address" = "${wgAddr}:${toString node.services.incus.port}";
      };
      certificates = [
        {
          certificate = builtins.readFile ../../secrets/incus-client.crt;
          name = "tofu-automation";
        }
      ];
      networks = [
        {
          name = incusNetwork.interface;
          type = "bridge";
          config = {
            "ipv4.address" = "${incusNodeNetwork.ip}/${incusPrefix}";
            "ipv4.nat" = "true";
          };
        }
      ];
      storage_pools = [
        {
          name = "default";
          driver = "dir";
          config = {
            source = "/var/lib/incus/storage-pools/default";
          };
        }
      ];
      profiles = [
        {
          name = "default";
          devices = {
            eth0 = {
              name = "eth0";
              network = incusNetwork.interface;
              type = "nic";
            };
            root = {
              path = "/";
              pool = "default";
              size = "20GiB";
              type = "disk";
            };
          };
        }
      ];
    };
  };
}
