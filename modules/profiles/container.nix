{
  lib,
  modulesPath,
  ...
}:

{
  imports = [
    (modulesPath + "/virtualisation/lxc-container.nix")
  ];

  networking.useNetworkd = true;
  networking.useDHCP = false;
  # lxc-container.nix sets useHostResolvConf = true; override it since we use
  # systemd-resolved (enabled by useNetworkd) with DNS provided by Incus DHCP.
  networking.useHostResolvConf = lib.mkForce false;

  # Incus bridge DHCP always hands out the static IP defined in the NIC device's
  # ipv4.address property, so DHCP here gives us a deterministic address.
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

  # Container root is Incus-managed and persists across reboots, so
  # /var/lib/nixos is never lost. The impermanence UID/GID warning is a
  # false positive here — disable it fleet-wide for containers.
  environment.persistence."/persist".enableWarnings = false;

  # Enable udev to provide 'udevadm'. lxc-container.nix uses this to trigger
  # device events, which systemd-networkd requires to fully initialize eth0
  # for IPv4 DHCP in unprivileged containers.
  services.udev.enable = lib.mkForce true;

  # Disable wait-online to prevent 2-minute boot hangs.
  systemd.services.systemd-networkd-wait-online.enable = lib.mkForce false;
}
