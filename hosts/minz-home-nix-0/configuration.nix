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
  incusClientCert = pkgs.writeText "incus-client.crt" (
    builtins.readFile ../../secrets/incus-client.crt
  );
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
  boot.supportedFilesystems = [ "nfs" ];
  # Enable IOMMU for general isolation. GPU access for jellyfin-0 uses DRM character
  # device passthrough (not PCI passthrough) to avoid IOMMU group issues.
  boot.kernelParams = [
    "intel_iommu=on"
    "iommu=pt"
  ];

  # AppArmor enforces Incus's per-VM confinement profiles at the host kernel level.
  # Without this the profiles are generated but not enforced.
  security.apparmor.enable = true;

  networking.nftables.enable = true;
  networking.firewall.trustedInterfaces = [ incusNetwork.interface ];

  systemd.network = {
    netdevs."10-vlan10" = {
      netdevConfig = {
        Name = "vlan10";
        Kind = "vlan";
      };
      vlanConfig.Id = 10;
    };
    networks."20-eno1" = {
      matchConfig.Name = "eno1";
      vlan = [ "vlan10" ];
      networkConfig.DHCP = "ipv4";
      dhcpV4Config.UseGateway = false;
    };
    networks."30-vlan10" = {
      matchConfig.Name = "vlan10";
      networkConfig.DHCP = "ipv4";
      linkConfig.RequiredForOnline = "routable";
    };
  };

  services.openssh.listenAddresses = [
    {
      addr = wgAddr;
      port = node.services.ssh.port;
    }
  ];

  users.users.minz1 = {
    description = "Minz One";
    extraGroups = [
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

  # --- NFS mounts from minz-arr-0 ---
  # These are mounted on the host and then bind-mounted into the unprivileged
  # jellyfin container via Incus disk devices. This avoids the need for
  # mount syscall interception and relaxes security profiles inside the container.
  fileSystems."/mnt/nfs/data" = {
    device = "10.10.0.4:/data";
    fsType = "nfs4";
    options = [
      "ro"
      "noatime"
      "soft"
      "timeo=30"
      "_netdev"
    ];
  };

  fileSystems."/mnt/nfs/decypharr" = {
    device = "10.10.0.4:/mnt/decypharr";
    fsType = "nfs4";
    options = [
      "ro"
      "noatime"
      "soft"
      "timeo=30"
      "_netdev"
    ];
  };

  systemd.tmpfiles.rules = [
    "d /mnt/nfs/data          0755 root root -"
    "d /mnt/nfs/decypharr     0755 root root -"
  ];

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
