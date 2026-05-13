{ lib, hostName }:

let
  topology = import ./topology.nix;

  me = topology.${hostName};
  isServer = me.role == "server";

  relevantPeers =
    if isServer then
      lib.filterAttrs (name: _: name != hostName) topology
    else
      lib.filterAttrs (_: peer: peer.role == "server") topology;

  toPeer =
    name: peer:
    {
      publicKey = peer.publicKey;
      allowedIPs = if isServer then [ "${peer.ip}/32" ] else [ "10.8.0.0/24" ];
    }
    // lib.optionalAttrs (!isServer) {
      endpoint = peer.endpoint;
      persistentKeepalive = 25;
    };
in
{
  wg0 = {
    ips = [ "${me.ip}/24" ];
    privateKeyFile = "/var/lib/wireguard/private";
    peers = lib.mapAttrsToList toPeer relevantPeers;
  }
  // lib.optionalAttrs isServer {
    listenPort = 51820;
  };
}
