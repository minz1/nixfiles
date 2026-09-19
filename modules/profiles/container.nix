{
  lib,
  modulesPath,
  incusGatewayIp,
  ...
}:

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
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # Impermanence UID/GID warning is a false positive for Incus-managed container roots.
  environment.persistence."/persist".enableWarnings = false;

  # lxc-container.nix disables udev; re-enable so systemd-networkd can init eth0.
  services.udev.enable = lib.mkForce true;

  # Disable wait-online to prevent 2-minute boot hangs.
  systemd.services.systemd-networkd-wait-online.enable = lib.mkForce false;

  services.timesyncd.servers = [ incusGatewayIp ];
}
