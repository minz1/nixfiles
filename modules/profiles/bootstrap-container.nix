{ lib, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/virtualisation/lxc-container.nix")
    ../nixos/common.nix
  ];

  networking.hostName = lib.mkDefault "nixos-bootstrap";
  networking.useNetworkd = true;
  networking.useDHCP = false;
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

  system.stateVersion = "25.11";
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  services.udev.enable = lib.mkForce true;
  systemd.services.systemd-networkd-wait-online.enable = lib.mkForce false;
}
