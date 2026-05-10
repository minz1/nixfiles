{ lib, hostName }:

let
  topology = {
    minz-vultr-nix-0 = {
      role = "server";
      ip = "10.8.0.1";
      publicKey = "R42VqreOxYnlgs6SoaX+uOHrzComhJcOMshgjjXHcBc=";
      endpoint = "144.202.58.162:51820";
    };
    device-2 = {
      role = "client";
      ip = "10.8.0.2";
      publicKey = "kvjC79ivkCmFXBUiJm2wt4SLoyFrlxyiZvOffSraJCc=";
    };
    device-3 = {
      role = "client";
      ip = "10.8.0.3";
      publicKey = "t/NvyVClqspHWixGJzjWBOnbfm4AyZNEdF9NGT1hWw4=";
    };
    minz-desktop = {
      role = "client";
      ip = "10.8.0.4";
      publicKey = "E/ptYaj0yogTCFlHuvnYV88NLErGdOL5F8p/PeW6JXM=";
    };
    minz-home-vm-0 = {
      role = "client";
      ip = "10.8.0.5";
      publicKey = "82wMGARWEdw9PGqZXYGRoo/fYOaCffokD3BOv/4mEG0=";
    };
  };

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
