{
  config,
  pkgs,
  lib,
  hostName,
  topology,
  node,
  ...
}:

let
  incusNetwork = topology.networks.incus_bridge;
  incusNodeNetwork = node.networks.incus_bridge;
  wgAddr = node.networks.mgmt.ip;
  incusPrefix = lib.last (lib.splitString "/" incusNetwork.subnet);
  incusClientCert = ../../secrets/incus-client.crt;

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

  system.stateVersion = "25.11";

  # Bare-metal EFI — canTouchEfiVariables is required for lanzaboote key enrollment.
  boot.loader.efi.canTouchEfiVariables = true;
  # Newest kernel with a working ZFS module — usually linuxPackages_latest (needed for Intel Arc A310).
  boot.kernelPackages =
    let
      kmod = pkgs.zfs.kernelModuleAttribute;
      isPlainVersioned = name: builtins.match "linux_[0-9]+_[0-9]+" name != null;
      candidates = lib.filterAttrs (name: _: isPlainVersioned name) pkgs.linuxKernel.packages;
      compatible = lib.filterAttrs (
        _: lp: (builtins.tryEval (lp ? ${kmod} && !(lp.${kmod}.meta.broken or true))).value or false
      ) candidates;
    in
    lib.last (
      lib.sort (a: b: lib.versionOlder a.kernel.version b.kernel.version) (lib.attrValues compatible)
    );
  warnings =
    lib.optional (config.boot.kernelPackages.kernel.version != pkgs.linuxPackages_latest.kernel.version)
      "home-nix-0: ZFS pinned the kernel to ${config.boot.kernelPackages.kernel.version}, behind linuxPackages_latest (${pkgs.linuxPackages_latest.kernel.version}). Re-check Intel Arc transcoding on media-0.";
  boot.supportedFilesystems = {
    nfs = true;
    zfs = true;
  };
  networking.hostId = "89cfdf56"; # unique per host, required by ZFS
  boot.extraModprobeConfig = ''
    options zfs zfs_arc_max=4294967296
  '';
  services.zfs.autoScrub = {
    enable = true;
    interval = "monthly";
  };
  boot.zfs.forceImportRoot = false; # no ZFS root pool here (tmpfs+ext4)
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

  programs.neovim = {
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
  };
  environment.systemPackages = with pkgs; [
    opentofu
    sops
  ];

  # Real mount, not impermanence — Incus VM volumes survive reboots here.
  disko.devices.disk.incus = {
    device = node.storage.incus_disk;
    content = {
      type = "gpt";
      partitions.data = {
        size = "100%";
        type = "BF00";
        content = {
          type = "zfs";
          pool = "incus";
        };
      };
    };
  };

  disko.devices.zpool.incus = {
    type = "zpool";
    options = {
      ashift = "12";
      autotrim = "on";
    };
    rootFsOptions = {
      compression = "lz4";
      atime = "off";
      xattr = "sa";
      acltype = "posixacl";
      mountpoint = "none";
    };
    datasets = {
      daemon = {
        type = "zfs_fs";
        mountpoint = "/var/lib/incus";
      };
      pool = {
        type = "zfs_fs";
        options.mountpoint = "none";
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
          driver = "zfs";
          config = {
            source = "incus/pool";
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
  environment.etc."alloy/router.alloy".text = ''
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

  # Alloy's syslog listener loads cert_file/key_file once at startup and never re-reads them (Go TLS caching);
  # acme's reloadServices would only SIGHUP it, which isn't reliable here, so force a full restart on renewal.
  security.acme.certs."${hostName}.internal".postRun = "systemctl restart alloy.service";

  systemd.services.incus-add-tofu-cert = {
    description = "Add tofu-automation client certificate to Incus trust store";
    after = [ "incus-preseed.service" ];
    wantedBy = [ "incus.service" ];
    partOf = [ "incus.service" ];
    path = [
      pkgs.incus
      pkgs.openssl
    ];
    # fingerprint-aware so rotating secrets/incus-client.* is just a deploy: stale tofu-automation entries are removed
    restartTriggers = [ incusClientCert ];
    script = ''
      fp=$(openssl x509 -in ${incusClientCert} -noout -fingerprint -sha256 | cut -d= -f2 | tr -d : | tr '[:upper:]' '[:lower:]')
      present=false
      while IFS=, read -r name short; do
        [ "$name" = "tofu-automation" ] || continue
        if [ "$short" = "''${fp:0:12}" ]; then
          present=true
        else
          incus config trust remove "$short"
        fi
      done < <(incus config trust list -f csv | cut -d, -f1,4)
      "$present" || incus config trust add-certificate ${incusClientCert} --name=tofu-automation --type=client
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
  };
}
