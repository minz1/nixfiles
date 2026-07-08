# Global topology module for nix-topology; hand-derives WireGuard/Incus-bridge interfaces from common/topology.nix since its extractors can't see either.
{ lib, config, ... }:
let
  data = import ./topology.nix;
  inherit (data) networks nodes;

  networkNames = {
    mgmt = "Management (WireGuard)";
    edge = "Edge (WireGuard)";
    incus_bridge = "Incus Bridge";
  };

  nodeIcons = {
    minz-desktop = "devices.laptop";
  };

  topoNetworks = lib.mapAttrs (name: net: {
    name = networkNames.${name} or name;
    cidrv4 = net.subnet;
  }) networks;

  # node with role "server"/"gateway" on a network is the hub everyone else connects to
  hubOf =
    netName:
    let
      members = lib.filterAttrs (_: n: n.networks ? ${netName}) nodes;
      hubs = lib.filterAttrs (
        _: n:
        builtins.elem (n.networks.${netName}.role or "") [
          "server"
          "gateway"
        ]
      ) members;
    in
    if hubs == { } then null else lib.head (lib.attrNames hubs);

  # keyed by the real interface name so this merges into the extractor's auto-detected wg0/wg1 instead of duplicating it
  mkInterface =
    node: netName: netCfg:
    let
      net = networks.${netName};
      hub = hubOf netName;
      isWireguard = net.type == "wireguard";
      # extractor already finds this address on nixos hosts; don't duplicate it
      extractorCoversAddress = isWireguard && node.os == "nixos";
    in
    lib.optionalAttrs (!extractorCoversAddress) { addresses = [ netCfg.ip ]; }
    // {
      network = netName;
    }
    // lib.optionalAttrs isWireguard {
      type = "wireguard";
      virtual = true;
    }
    // lib.optionalAttrs (hub != null && hub != node.name) {
      physicalConnections = [
        {
          node = hub;
          interface = net.interface or netName;
        }
      ];
    };

  topoNodes = lib.mapAttrs (
    nodeName: node:
    lib.optionalAttrs (node.os == "external") { deviceType = "device"; }
    // lib.optionalAttrs (nodeIcons ? ${nodeName}) { icon = nodeIcons.${nodeName}; }
    // {
      interfaces = lib.mapAttrs' (
        netName: netCfg:
        lib.nameValuePair (networks.${netName}.interface or netName) (
          mkInterface (node // { name = nodeName; }) netName netCfg
        )
      ) node.networks;
    }
  ) nodes;

  # nix-topology has no podman/docker extractor, so pick up virtualisation.quadlet.containers ourselves
  quadletNodes = lib.mapAttrs (hostName: nixos: {
    services = lib.mapAttrs (containerName: container: {
      name = containerName;
      icon = ./icons/podman.svg;
      info = container.containerConfig.image or "";
    }) (nixos.config.virtualisation.quadlet.containers or { });
  }) config.nixosConfigurations;
in
{
  networks = topoNetworks;

  nodes = lib.recursiveUpdate (lib.recursiveUpdate topoNodes quadletNodes) {
    # decorative link to match docs/architecture.md; not part of common/topology.nix
    internet = {
      deviceType = "internet";
      name = "Internet";
      interfaces.wan = { };
    };

    minz-vultr-nix-1.interfaces.wan = {
      addresses = [ "144.202.63.186" ];
      physicalConnections = [
        {
          node = "internet";
          interface = "wan";
        }
      ];
    };
  };
}
