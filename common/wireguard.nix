# Auto-configures WireGuard interfaces + IP forwarding for hosts with a wireguard-type network in common/topology.nix; private keys are sops secrets named wg_private_<networkName>.
{
  config,
  lib,
  topology,
  fleet,
  ...
}:

let
  inherit (topology) nodes networks;

  hostName = config.networking.hostName;
  currentNode =
    nodes.${hostName}
      or (throw "wireguard.nix: no topology entry for '${hostName}'. Add it to common/topology.nix.");

  # Only the WireGuard-type networks that this host participates in.
  wireguardNetworks = lib.filterAttrs (
    networkName: networkConfig:
    (builtins.hasAttr networkName currentNode.networks) && (networkConfig.type == "wireguard")
  ) networks;

  sshdListenIps = map (a: a.addr) config.services.openssh.listenAddresses;
  sshdWaitOnline = lib.mapAttrsToList (
    _: netCfg: "systemd-networkd-wait-online@${netCfg.interface}.service"
  ) (lib.filterAttrs (n: _: lib.elem currentNode.networks.${n}.ip sshdListenIps) wireguardNetworks);

  # True if this host is a server on any WireGuard network (needs IP forwarding).
  isAnyServer = lib.any (networkName: currentNode.networks.${networkName}.role == "server") (
    lib.attrNames wireguardNetworks
  );

  generateInterface =
    networkName: networkConfig:
    let
      currentNetworkConfig = currentNode.networks.${networkName};
      isServer = currentNetworkConfig.role == "server";
      subnetPrefix = lib.last (lib.splitString "/" networkConfig.subnet);

      nodesInNetwork = lib.filterAttrs (_: node: builtins.hasAttr networkName node.networks) nodes;

      # extraAllowedIPs from other nodes so clients can reach subnets routed through peers, excluding our own to avoid local routing conflicts.
      otherNodesExtraAllowedIPs = lib.flatten (
        lib.mapAttrsToList (
          n: node: if n != hostName then node.networks.${networkName}.extraAllowedIPs else [ ]
        ) nodesInNetwork
      );

      # Hub-and-spoke: servers peer with everyone; clients only peer with servers.
      peers = lib.filterAttrs (
        otherName: otherNode:
        (otherName != hostName)
        && (builtins.hasAttr networkName otherNode.networks)
        && (isServer || otherNode.networks.${networkName}.role == "server")
      ) nodes;

      toPeer =
        _: node:
        let
          peerCfg = node.networks.${networkName};
        in
        {
          inherit (peerCfg) publicKey;
          allowedIPs =
            if isServer then
              [ "${peerCfg.ip}/32" ] ++ peerCfg.extraAllowedIPs
            else
              lib.unique ([ networkConfig.subnet ] ++ otherNodesExtraAllowedIPs);
        }
        // lib.optionalAttrs (peerCfg.endpoint != null) {
          inherit (peerCfg) endpoint;
          persistentKeepalive = 25;
        };
    in
    {
      name = networkConfig.interface;
      value = {
        ips = [ "${currentNetworkConfig.ip}/${subnetPrefix}" ];
        privateKeyFile = config.sops.secrets."wg_private_${networkName}".path;
        peers = lib.mapAttrsToList toPeer peers;
      }
      // lib.optionalAttrs isServer {
        inherit (networkConfig) listenPort;
      };
    };

  fw = config.networking.firewall;
  fleetPorts = config.homelab.wireguard.fleetTCPPorts;
  csv = lib.concatMapStringsSep ", " toString;
  wgInterfaces = lib.mapAttrsToList (_: n: n.interface) wireguardNetworks;
  opens =
    c: port:
    lib.elem port (c.allowedTCPPorts or [ ])
    || lib.any (r: r.from <= port && port <= r.to) (c.allowedTCPPortRanges or [ ]);
  openToAll = lib.filter (
    port: lib.any (c: opens c port) ([ fw ] ++ map (i: fw.interfaces.${i} or { }) wgInterfaces)
  ) fleetPorts;
in
{
  options.homelab.wireguard.fleetTCPPorts = lib.mkOption {
    type = lib.types.listOf lib.types.port;
    default = [ ];
    description = "TCP ports on the mgmt WireGuard interface open only to fleet hosts and admin-client nodes.";
  };

  config = {
    networking.wireguard.interfaces = builtins.listToAttrs (
      lib.mapAttrsToList generateInterface wireguardNetworks
    );

    # Servers route packets between peers — requires IP forwarding at the kernel level.
    boot.kernel.sysctl = lib.optionalAttrs isAnyServer {
      "net.ipv4.ip_forward" = 1;
    };

    # Declare a sops secret for each WG network this host participates in.
    sops.secrets = builtins.listToAttrs (
      lib.mapAttrsToList (networkName: _: {
        name = "wg_private_${networkName}";
        value = { };
      }) wireguardNetworks
    );

    # Open the listen port for each network where this host is a server.
    networking.firewall.allowedUDPPorts = lib.flatten (
      lib.mapAttrsToList (
        networkName: networkConfig:
        let
          currentNetCfg = currentNode.networks.${networkName};
        in
        lib.optional (currentNetCfg.role == "server") (networkConfig.listenPort)
      ) wireguardNetworks
    );

    # sshd binds a WG IP; networking.wireguard runs on networkd here, so wait for the link's address, not a wireguard-wgN unit
    systemd.services.sshd.after = sshdWaitOnline;
    systemd.services.sshd.wants = sshdWaitOnline;

    # default RestartSec=100ms + StartLimitBurst=5/10s burns the whole retry budget in ~0.5s
    systemd.services.sshd.serviceConfig.RestartSec = lib.mkIf (wireguardNetworks != { }) 5;
    systemd.services.sshd.startLimitBurst = lib.mkIf (wireguardNetworks != { }) 20;
    systemd.services.sshd.startLimitIntervalSec = lib.mkIf (wireguardNetworks != { }) 300;

    networking.firewall.extraInputRules = lib.mkIf (fleetPorts != [ ]) ''
      iifname "${topology.networks.mgmt.interface}" ip saddr { ${csv (fleet.fleetSourcesFor hostName)} } tcp dport { ${csv fleetPorts} } accept
    '';

    assertions = [
      {
        assertion = fleetPorts == [ ] || fw.backend == "nftables";
        message = "homelab.wireguard.fleetTCPPorts needs networking.firewall.backend = \"nftables\" (extraInputRules renders only there).";
      }
      {
        assertion = !lib.any (i: lib.elem i fw.trustedInterfaces) wgInterfaces;
        message = "common/wireguard.nix: a WireGuard interface in trustedInterfaces opens every port to every peer.";
      }
      {
        assertion = openToAll == [ ];
        message = "homelab.wireguard.fleetTCPPorts ${csv openToAll} also open to every source via allowedTCPPorts/allowedTCPPortRanges (global or WireGuard interface).";
      }
    ];
  };
}
