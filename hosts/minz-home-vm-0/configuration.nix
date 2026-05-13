{
  config,
  pkgs,
  lib,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "minz-home-vm-0";
  system.stateVersion = "25.11";

  networking.wireguard.interfaces = import ../../common/wireguard.nix {
    inherit lib;
    hostName = config.networking.hostName;
  };

  networking.networkmanager.enable = true;
  networking.nftables.enable = true;

  services.decypharr = {
    enable = true;
    mediaPath = "/mnt/debrid";
    mediaGroup = "media";
  };

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
  environment.systemPackages = with pkgs; [ opentofu ];
  environment.shellAliases = {
    vi = "nvim";
    vim = "nvim";
  };

  virtualisation.incus = {
    enable = true;
    preseed = {
      config = {
        "core.https_address" = "10.8.0.5:8443";
      };
      networks = [
        {
          name = "incusbr0";
          type = "bridge";
          config = {
            "ipv4.address" = "10.10.0.1/24";
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
              network = "incusbr0";
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
