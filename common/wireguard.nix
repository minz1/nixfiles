# Auto-configures WireGuard interfaces + IP forwarding for hosts with a wireguard-type network in common/topology.nix; private keys are sops secrets named wg_private_<networkName>.
{ config, lib, ... }:

let
  topology = import ./topology.nix;
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
          n: node: if n != hostName then (node.networks.${networkName}.extraAllowedIPs or [ ]) else [ ]
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
              [ "${peerCfg.ip}/32" ] ++ (peerCfg.extraAllowedIPs or [ ])
            else
              lib.unique ([ networkConfig.subnet ] ++ otherNodesExtraAllowedIPs);
        }
        // lib.optionalAttrs (peerCfg ? endpoint) {
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
        listenPort = currentNetworkConfig.listenPort or networkConfig.listenPort or 51820;
      };
    };

in
{
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
      value = {
        mode = "0400";
      };
    }) wireguardNetworks
  );

  # Open the listen port for each network where this host is a server.
  networking.firewall.allowedUDPPorts = lib.flatten (
    lib.mapAttrsToList (
      networkName: networkConfig:
      let
        currentNetCfg = currentNode.networks.${networkName};
      in
      lib.optional (currentNetCfg.role == "server") (
        currentNetCfg.listenPort or networkConfig.listenPort or 51820
      )
    ) wireguardNetworks
  );

  # All WG interfaces carry internal traffic and are trusted.
  networking.firewall.trustedInterfaces = lib.mapAttrsToList (
    _: netCfg: netCfg.interface
  ) wireguardNetworks;

  # sshd binds a WG IP but wireguard-wgN.service going active doesn't guarantee the address is bindable yet.
  systemd.services.sshd.after = lib.mapAttrsToList (
    _: netCfg: "wireguard-${netCfg.interface}.service"
  ) wireguardNetworks;
  systemd.services.sshd.wants = lib.mapAttrsToList (
    _: netCfg: "wireguard-${netCfg.interface}.service"
  ) wireguardNetworks;

  # default RestartSec=100ms + StartLimitBurst=5/10s burns the whole retry budget in ~0.5s
  systemd.services.sshd.serviceConfig.RestartSec = lib.mkIf (wireguardNetworks != { }) 5;
  systemd.services.sshd.startLimitBurst = lib.mkIf (wireguardNetworks != { }) 20;
  systemd.services.sshd.startLimitIntervalSec = lib.mkIf (wireguardNetworks != { }) 300;
}
