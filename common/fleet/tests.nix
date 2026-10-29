{ lib, mkFleet }:
let
  base = {
    inherit lib;
    hostDirs = [
      "hub"
      "edgevps"
      "host"
      "guest"
    ];
    topology = {
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
        desktop = {
          kind = "device";
          networks.mgmt = {
            ip = "10.8.0.4";
            role = "client";
          };
        };
        hub = {
          kind = "vps";
          storage = {
            disk = "/dev/vda";
            nix_gib = 20;
          };
          networks.mgmt = {
            ip = "10.8.0.1";
            role = "server";
            endpoint = "192.0.2.1:51820";
          };
        };
        edgevps = {
          kind = "vps";
          storage = {
            disk = "/dev/vda";
            nix_gib = 20;
          };
          networks = {
            mgmt = {
              ip = "10.8.0.6";
              role = "client";
            };
            edge = {
              ip = "10.9.0.1";
              role = "server";
              endpoint = "192.0.2.2:51820";
            };
          };
        };
        host = {
          kind = "incus-host";
          storage = {
            disk = "/dev/nvme0n1";
            nix_gib = 60;
          };
          networks = {
            mgmt = {
              ip = "10.8.0.5";
              role = "client";
            };
            edge = {
              ip = "10.9.0.2";
              role = "client";
            };
            incus_bridge = {
              ip = "10.10.0.1";
              role = "gateway";
            };
          };
        };
        guest = {
          kind = "incus-vm";
          incus = {
            cpus = 2;
            memory_gib = 2;
            nix_gib = 10;
            total_gib = 20;
          };
          networks.incus_bridge.ip = "10.10.0.2";
        };
      };
    };
    services =
      { config, ... }:
      {
        services.svc = {
          host = config.nodes.guest.name;
          port = 443;
        };
      };
  };

  f = mkFleet base;
  evaluates = args: (builtins.tryEval (builtins.deepSeq (mkFleet args) true)).success;
  with' = patch: lib.recursiveUpdate base patch;
  withServices = extra: {
    services =
      { config, ... }:
      {
        imports = [ base.services ];
        services = extra config;
      };
  };
in
{
  unit = lib.runTests {
    testShared = {
      expr = f.addressOf "host" "guest";
      expected = "10.10.0.2";
    };
    testMgmtOverEdge = {
      expr = f.addressOf "host" "edgevps";
      expected = "10.8.0.6";
    };
    testRoutedDesktopGuest = {
      expr = f.addressOf "desktop" "guest";
      expected = "10.10.0.2";
    };
    testRoutedGuestVps = {
      expr = f.addressOf "guest" "edgevps";
      expected = "10.8.0.6";
    };
    testRoutedVpsGuest = {
      expr = f.addressOf "hub" "guest";
      expected = "10.10.0.2";
    };
    testUnknownFrom = {
      expr = f.addressOf "nixos-bootstrap" "host";
      expected = "10.8.0.5";
    };
    testEndpointsFor = {
      expr = (f.endpointsFor "hub").svc;
      expected = {
        ip = "10.10.0.2";
        port = 443;
      };
    };
    testDefaults = {
      expr = {
        inherit (f.nodes.edgevps.networks.mgmt) endpoint extraAllowedIPs;
      };
      expected = {
        endpoint = null;
        extraAllowedIPs = [ ];
      };
    };
  };

  positive = evaluates base;

  negative = map (n: n // { failed = !(evaluates n.args); }) [
    {
      name = "service host not a node";
      args =
        base
        // withServices (_: {
          other = {
            host = "guestx";
            port = 80;
          };
        });
    }
    {
      name = "ip outside subnet";
      args = with' { topology.nodes.guest.networks.incus_bridge.ip = "10.11.0.2"; };
    }
    {
      name = "duplicate ip";
      args = with' { topology.nodes.guest.networks.incus_bridge.ip = "10.10.0.1"; };
    }
    {
      name = "second mgmt server";
      args = with' { topology.nodes.edgevps.networks.mgmt.role = "server"; };
    }
    {
      name = "endpoint on a client";
      args = with' { topology.nodes.host.networks.mgmt.endpoint = "192.0.2.3:51820"; };
    }
    {
      name = "two services on one host:port";
      args =
        base
        // withServices (config: {
          other = {
            host = config.nodes.guest.name;
            port = 443;
          };
        });
    }
    {
      name = "persist under 4 GiB";
      args = with' {
        topology.nodes.guest.incus = {
          nix_gib = 18;
          total_gib = 20;
        };
      };
    }
    {
      name = "host dir without node";
      args = base // {
        hostDirs = base.hostDirs ++ [ "ghost" ];
      };
    }
    {
      name = "non-/24 subnet";
      args = with' { topology.networks.incus_bridge.subnet = "10.10.0.0/16"; };
    }
  ];
}
