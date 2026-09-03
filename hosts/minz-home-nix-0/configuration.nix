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

  # fed by stunnel client mode on the router
  routerSyslogPort = 1514; # unprivileged; DynamicUser Alloy lacks CAP_NET_BIND_SERVICE
  certDir = "/var/lib/acme/${hostName}.internal";
  routerIp = "192.168.0.1";
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
  # i915 for stability on Small BAR hardware; enable_guc=3 required for Arc DG2 scheduling.
  boot.kernelParams = [
    "intel_iommu=on"
    "iommu=pt"
    "i915.enable_guc=3"
  ];

  # Without AppArmor, Incus confinement profiles are generated but not enforced.
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
      port = 22;
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

  # Real mount, not impermanence — Incus VM volumes survive reboots here.
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
        "core.https_address" = "${wgAddr}:8443";
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

  # No Caddy on this host, but group is needed for ACME cert readability by Alloy.
  users.groups.caddy = { };

  # NTP server for incus-bridge VMs; incusbr0 is trusted so no firewall rule needed.
  services.chrony = {
    enable = true;
    extraConfig = "allow ${incusNetwork.subnet}";
  };

  # Intel I219 (e1000e) hardware unit hang fix — TSO/GSO cause tx ring stalls.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="net", KERNEL=="eno1", RUN+="${pkgs.ethtool}/bin/ethtool -K eno1 tso off gso off"
  '';

  # syslog_format = rfc3164 is a best guess for the real logread output — no parse errors seen, but confirm live in Grafana Explore.
  homelab.observability.extraAlloyConfig = ''
    loki.source.syslog "router" {
      listener {
        address       = "0.0.0.0:${toString routerSyslogPort}"
        protocol      = "tcp"
        syslog_format = "rfc3164"
        labels = {
          job = "openwrt-syslog",
        }

        tls_config {
          cert_file = "${certDir}/fullchain.pem"
          key_file  = "${certDir}/key.pem"
        }
      }

      forward_to = [loki.write.default.receiver]
    }
  '';

  # nftables-native equivalent of extraCommands — required since this host has networking.nftables.enable = true
  networking.firewall.extraInputRules = ''
    ip saddr ${routerIp} tcp dport ${toString routerSyslogPort} accept
  '';

  # Alloy's syslog listener loads cert_file/key_file once at startup and never re-reads them (Go TLS caching); acme's reloadServices would only SIGHUP it, which isn't reliable here, so this path unit forces a full restart whenever cert.pem's content changes.
  systemd.paths.alloy-cert-renewed = {
    wantedBy = [ "multi-user.target" ];
    pathConfig.PathChanged = "${certDir}/cert.pem";
  };
  systemd.services.alloy-cert-renewed = {
    serviceConfig.Type = "oneshot";
    script = "systemctl restart alloy.service";
    path = [ pkgs.systemd ];
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
