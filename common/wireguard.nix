# NixOS module — automatically configures WireGuard interfaces and IP forwarding
# for any host that has a wireguard-type network in common/topology.nix.
#
# Reads config.networking.hostName to self-identify in the topology.
# Private key is sourced from the sops-nix secret "wg_private" (convention).
{ config, lib, ... }:

let
  topology = import ./topology.nix;
  nodes = topology.nodes;
  networks = topology.networks;

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

      # All extraAllowedIPs declared by any node in this network (e.g. the Incus bridge subnet).
      # Clients receive these so they can reach subnets routed through other peers.
      allExtraAllowedIPs = lib.flatten (
        lib.mapAttrsToList (_: node: node.networks.${networkName}.extraAllowedIPs or [ ]) nodesInNetwork
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
          publicKey = peerCfg.publicKey;
          allowedIPs =
            if isServer then
              [ "${peerCfg.ip}/32" ] ++ (peerCfg.extraAllowedIPs or [ ])
            else
              lib.unique ([ networkConfig.subnet ] ++ allExtraAllowedIPs);
        }
        // lib.optionalAttrs (peerCfg ? endpoint) {
          endpoint = peerCfg.endpoint;
          persistentKeepalive = 25;
        };
    in
    {
      name = networkConfig.interface;
      value = {
        ips = [ "${currentNetworkConfig.ip}/${subnetPrefix}" ];
        # Convention: the WireGuard private key is managed as a sops secret named "wg_private".
        privateKeyFile = config.sops.secrets.wg_private.path;
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
}
