{
  lib,
  modulesPath,
  ...
}:

let
  topology = import ../../common/topology.nix;
  incusHostNode = lib.findFirst (
    n: (n.provisioner or "") == "incus-host"
  ) (throw "No incus-host node in topology") (lib.attrValues topology.nodes);
  gatewayIp = incusHostNode.networks.incus_bridge.ip;
in

{
  imports = [
    (modulesPath + "/virtualisation/lxc-container.nix")
  ];

  networking.useNetworkd = true;
  networking.useDHCP = false;
  # lxc-container.nix overrides to true; reset since we use systemd-resolved.
  networking.useHostResolvConf = lib.mkForce false;

  systemd.network.networks."10-eth0" = {
    matchConfig.Name = "eth0";
    networkConfig.DHCP = "ipv4";
    linkConfig.RequiredForOnline = "routable";
  };

  services.openssh.listenAddresses = [
    {
      addr = "0.0.0.0";
      port = 22;
    }
  ];
  networking.firewall.allowedTCPPorts = [ 22 ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # Impermanence UID/GID warning is a false positive for Incus-managed container roots.
  environment.persistence."/persist".enableWarnings = false;

  # lxc-container.nix disables udev; re-enable so systemd-networkd can init eth0.
  services.udev.enable = lib.mkForce true;

  # Disable wait-online to prevent 2-minute boot hangs.
  systemd.services.systemd-networkd-wait-online.enable = lib.mkForce false;

  services.timesyncd.servers = [ gatewayIp ];

  # Egress ACL blocks cache.nixos.org; deploy-rs nix copy provides the full closure.
  nix.settings.substituters = lib.mkForce [ ];
}
