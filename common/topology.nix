{
  networks = {
    mgmt = {
      type = "wireguard";
      subnet = "10.8.0.0/24";
      interface = "wg0";
      listenPort = 51820;
    };
    edge = {
      type = "wireguard";
      subnet = "10.9.0.0/24";
      interface = "wg1";
      listenPort = 51820;
    };
    incus_bridge = {
      type = "incus";
      subnet = "10.10.0.0/24";
      interface = "incusbr0";
    };
  };

  nodes = {
    minz-vultr-nix-1 = {
      os = "nixos";
      sshUser = "minz1";
      storage = {
        disk = "/dev/vda";
        nix_size = "20G";
      };
      services = {
        ssh.port = 22;
      };
      networks = {
        mgmt = {
          ip = "10.8.0.6";
          role = "client";
          publicKey = "q/T9w4if7+hSzwGQ1Rez7LrPmuKNGUEJIzL6WhQFIAo=";
          endpoint = "144.202.63.186:51820";
        };
        edge = {
          ip = "10.9.0.1";
          role = "server";
          publicKey = "qgN5hkR3bAH3Ae+oTLgGjtOOTzkm1yFbMpir7m9beFs=";
          endpoint = "144.202.63.186:51820";
        };
      };
    };

    minz-vultr-nix-0 = {
      os = "nixos";
      ci_managed = false;
      sshUser = "minz1";
      storage = {
        disk = "/dev/vda";
        nix_size = "20G";
      };
      services = {
        ssh.port = 22;
        forgejo.port = 3000;
        rustfs.ports = [
          9000
          9001
        ];
      };
      networks.mgmt = {
        ip = "10.8.0.1";
        role = "server";
        publicKey = "R42VqreOxYnlgs6SoaX+uOHrzComhJcOMshgjjXHcBc=";
        endpoint = "144.202.58.162:51820";
      };
    };

    device-2 = {
      os = "external";
      networks.mgmt = {
        ip = "10.8.0.2";
        role = "client";
        publicKey = "kvjC79ivkCmFXBUiJm2wt4SLoyFrlxyiZvOffSraJCc=";
      };
    };

    device-3 = {
      os = "external";
      networks.mgmt = {
        ip = "10.8.0.3";
        role = "client";
        publicKey = "t/NvyVClqspHWixGJzjWBOnbfm4AyZNEdF9NGT1hWw4=";
      };
    };

    minz-desktop = {
      os = "external";
      networks.mgmt = {
        ip = "10.8.0.4";
        role = "client";
        publicKey = "E/ptYaj0yogTCFlHuvnYV88NLErGdOL5F8p/PeW6JXM=";
      };
    };

    minz-obs-0 = {
      os = "nixos";
      sshUser = "minz1";
      provisioner = "incus";
      deployed = true;
      incus = {
        nix_size = "30G";
        cpus = 2;
        memory = "2GiB";
      };
      services = {
        ssh.port = 22;
        prometheus.port = 9090;
        loki.port = 3100;
        grafana.port = 3000;
      };
      networks.incus_bridge = {
        ip = "10.10.0.2";
      };
    };

    minz-authentik-0 = {
      os = "nixos";
      sshUser = "minz1";
      provisioner = "incus";
      deployed = true;
      incus = {
        nix_size = "30G";
        cpus = 2;
        memory = "2GiB";
      };
      services = {
        ssh.port = 22;
        authentik.port = 9000;
      };
      networks.incus_bridge = {
        ip = "10.10.0.3";
      };
    };

    minz-home-nix-0 = {
      os = "nixos";
      sshUser = "minz1";
      provisioner = "incus-host";
      storage = {
        # 256GB NVMe — NixOS system disk
        disk = "/dev/disk/by-id/nvme-SAMSUNG_MZALQ256HAJD-000L1_S4YDNX0R638478";
        nix_size = "60G";
        # 500GB SATA SSD — Incus storage pool, ext4, mounted at /var/lib/incus
        incus_disk = "/dev/disk/by-id/ata-WDC_WDBNCE5000PNC_21112L803982";
      };
      services = {
        ssh.port = 22;
        incus.port = 8443;
      };
      networks = {
        mgmt = {
          ip = "10.8.0.5";
          role = "client";
          publicKey = "shqkweq2kj0ytkVnmF9iJMLPnxdDLls2cfmv7p/1gx8=";
          extraAllowedIPs = [ "10.10.0.0/24" ];
        };
        edge = {
          ip = "10.9.0.2";
          role = "client";
          publicKey = "5jZQ6SJ/TvsXkFhTV3U1MsNtTpeii0AsKSOM80KGiSE=";
          extraAllowedIPs = [ "10.10.0.0/24" ];
        };
        incus_bridge = {
          ip = "10.10.0.1";
          role = "gateway";
        };
      };
    };
  };
}
