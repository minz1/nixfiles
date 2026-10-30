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
      kind = "vps";
      storage = {
        disk = "/dev/vda";
        nix_gib = 20;
      };
      networks = {
        mgmt = {
          ip = "10.8.0.6";
          role = "client";
          publicKey = "q/T9w4if7+hSzwGQ1Rez7LrPmuKNGUEJIzL6WhQFIAo=";
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
      kind = "vps";
      storage = {
        disk = "/dev/vda";
        nix_gib = 20;
        rustfs_disk = "/dev/disk/by-id/virtio-ord-0120c5fa42b742";
      };
      networks.mgmt = {
        ip = "10.8.0.1";
        role = "server";
        publicKey = "R42VqreOxYnlgs6SoaX+uOHrzComhJcOMshgjjXHcBc=";
        endpoint = "144.202.58.162:51820";
      };
    };

    device-2 = {
      kind = "device";
      networks.mgmt = {
        ip = "10.8.0.2";
        role = "client";
        publicKey = "kvjC79ivkCmFXBUiJm2wt4SLoyFrlxyiZvOffSraJCc=";
      };
    };

    device-3 = {
      kind = "device";
      networks.mgmt = {
        ip = "10.8.0.3";
        role = "client";
        publicKey = "t/NvyVClqspHWixGJzjWBOnbfm4AyZNEdF9NGT1hWw4=";
      };
    };

    minz-desktop = {
      kind = "device";
      networks.mgmt = {
        ip = "10.8.0.4";
        role = "client";
        publicKey = "E/ptYaj0yogTCFlHuvnYV88NLErGdOL5F8p/PeW6JXM=";
      };
    };

    minz-obs-0 = {
      kind = "incus-vm";
      incus = {
        nix_gib = 30;
        total_gib = 100;
        cpus = 2;
        memory_gib = 4;
      };
      networks.incus_bridge = {
        ip = "10.10.0.2";
      };
    };

    minz-media-0 = {
      kind = "incus-container";
      incus = {
        root_gib = 160;
        cpus = 4;
        memory_gib = 14;
        gpu = true;
        nesting = true;
      };
      networks.incus_bridge = {
        ip = "10.10.0.7";
      };
    };

    minz-authentik-0 = {
      kind = "incus-vm";
      incus = {
        nix_gib = 30;
        total_gib = 100;
        cpus = 2;
        memory_gib = 2;
      };
      networks.incus_bridge = {
        ip = "10.10.0.3";
      };
    };

    minz-pki-0 = {
      kind = "incus-vm";
      incus = {
        nix_gib = 10;
        total_gib = 15;
        cpus = 1;
        memory_gib = 2;
      };
      networks.incus_bridge.ip = "10.10.0.8";
    };

    minz-game-0 = {
      kind = "incus-vm";
      incus = {
        nix_gib = 20;
        total_gib = 100;
        cpus = 4;
        memory_gib = 14;
      };
      networks.incus_bridge = {
        ip = "10.10.0.9";
      };
    };

    minz-services-0 = {
      kind = "incus-vm";
      incus = {
        nix_gib = 18;
        total_gib = 24;
        cpus = 2;
        memory_gib = 2;
      };
      networks.incus_bridge = {
        ip = "10.10.0.6";
      };
    };

    minz-attic-0 = {
      kind = "incus-vm";
      binaryCache = true;
      incus = {
        nix_gib = 20;
        total_gib = 100;
        cpus = 2;
        memory_gib = 2;
      };
      networks.incus_bridge.ip = "10.10.0.12";
    };

    minz-runner-0 = {
      kind = "incus-vm";
      incus = {
        nix_gib = 60;
        total_gib = 100;
        cpus = 4;
        memory_gib = 16;
      };
      networks.incus_bridge.ip = "10.10.0.13";
    };

    minz-home-nix-0 = {
      kind = "incus-host";
      storage = {
        # 256GB NVMe — NixOS system disk
        disk = "/dev/disk/by-id/nvme-SAMSUNG_MZALQ256HAJD-000L1_S4YDNX0R638478";
        nix_gib = 60;
        # 500GB SATA SSD — ZFS pool "incus", backs the Incus storage pool and /var/lib/incus
        incus_disk = "/dev/disk/by-id/ata-WDC_WDBNCE5000PNC_21112L803982";
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
