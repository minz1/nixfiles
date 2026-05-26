{
  pkgs,
  lib,
  hostName,
  ...
}:

let
  topology = import ../../common/topology.nix;
  node = topology.nodes."${hostName}";
  incusNetwork = topology.networks.incus_bridge;
  incusNodeNetwork = node.networks.incus_bridge;
  wgAddr = node.networks.mgmt.ip;
  incusPrefix = lib.last (lib.splitString "/" incusNetwork.subnet);
  incusClientCert = pkgs.writeText "incus-client.crt" (builtins.readFile ../../secrets/incus-client.crt);
in
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos/secureboot.nix
  ];

  networking.hostName = hostName;
  system.stateVersion = "25.11";

  # Bare-metal EFI — canTouchEfiVariables is required for lanzaboote key enrollment.
  boot.loader.efi.canTouchEfiVariables = true;
  # linuxPackages_latest required for Intel Arc A310 (xe driver, stable from ~6.8+).
  boot.kernelPackages = pkgs.linuxPackages_latest;
  # Enable IOMMU for Arc A310 GPU passthrough to Incus VMs (used in Phase 5f).
  boot.kernelParams = [
    "intel_iommu=on"
    "iommu=pt"
  ];

  # AppArmor enforces Incus's per-VM confinement profiles at the host kernel level.
  # Without this the profiles are generated but not enforced.
  security.apparmor.enable = true;

  networking.networkmanager.enable = true;
  networking.nftables.enable = true;
  networking.firewall.trustedInterfaces = [ incusNetwork.interface ];

  services.openssh.listenAddresses = [
    {
      addr = wgAddr;
      port = node.services.ssh.port;
    }
  ];

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

  # SATA SSD formatted ext4 and mounted at /var/lib/incus.
  # This is a real mount — not managed by impermanence — so Incus VM volumes
  # survive reboots without needing a /persist bind-mount.
  disko.devices.disk.incus = {
    device = node.storage.incus_disk;
    content = {
      type = "gpt";
      partitions.data = {
        size = "100%";
        content = {
          type = "filesystem";
          format = "ext4";
          mountpoint = "/var/lib/incus";
        };
      };
    };
  };

  virtualisation.incus = {
    enable = true;
    preseed = {
      config = {
        "core.https_address" = "${wgAddr}:${toString node.services.incus.port}";
      };
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

  systemd.services.incus-add-tofu-cert = {
    description = "Add tofu-automation client certificate to Incus trust store";
    after = [ "incus-preseed.service" ];
    wantedBy = [ "incus.service" ];
    partOf = [ "incus.service" ];
    path = [ pkgs.incus ];
    script = ''
      if incus config trust list | grep -q "tofu-automation"; then
        exit 0
      fi
      incus config trust add-certificate ${incusClientCert} --name=tofu-automation --type=client
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
  };
}
