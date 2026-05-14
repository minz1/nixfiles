{ lib, hostName }:

let
  topology = import ./topology.nix;
  nodes = topology.nodes;
  networks = topology.networks;

  currentNode = nodes.${hostName};

  wireguardNetworks = lib.filterAttrs (
    networkName: networkConfig:
    (builtins.hasAttr networkName currentNode.networks) && (networks.${networkName}.type == "wireguard")
  ) networks;

  generateInterface =
    networkName: networkConfig:
    let
      currentNetworkConfig = currentNode.networks.${networkName};
      isServer = currentNetworkConfig.role == "server";
      subnet = networkConfig.subnet;
      subnetPrefix = lib.last (lib.splitString "/" subnet);
      interfaceName = networkConfig.interface;

      nodesInNetwork = lib.filterAttrs (n: node: builtins.hasAttr networkName node.networks) nodes;

      allExtraAllowedIPs = lib.flatten (
        lib.mapAttrsToList (n: node: node.networks.${networkName}.extraAllowedIPs or [ ]) nodesInNetwork
      );

      wireguardPeers = lib.filterAttrs (
        otherName: otherNode:
        (otherName != hostName)
        && (builtins.hasAttr networkName otherNode.networks)
        &&
          # Hub-and-spoke: Servers talk to everyone, clients ONLY talk to servers
          (isServer || otherNode.networks.${networkName}.role == "server")
      ) nodes;

      toPeer =
        name: node:
        let
          peerNetworkConfig = node.networks.${networkName};
        in
        {
          publicKey = peerNetworkConfig.publicKey;
          allowedIPs =
            if isServer then
              [ "${peerNetworkConfig.ip}/32" ] ++ (peerNetworkConfig.extraAllowedIPs or [ ])
            else
              lib.unique ([ subnet ] ++ allExtraAllowedIPs);
        }
        // lib.optionalAttrs (peerNetworkConfig ? endpoint) {
          endpoint = peerNetworkConfig.endpoint;
          persistentKeepalive = 25;
        };
    in
    {
      name = interfaceName;
      value = {
        ips = [ "${currentNetworkConfig.ip}/${subnetPrefix}" ];
        privateKeyFile = "/var/lib/wireguard/private";
        peers = lib.mapAttrsToList toPeer wireguardPeers;
      }
      // lib.optionalAttrs isServer {
        listenPort = currentNetworkConfig.listenPort or networkConfig.listenPort or 51820;
      };
    };

in
builtins.listToAttrs (lib.mapAttrsToList generateInterface wireguardNetworks)
