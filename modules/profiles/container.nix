{ lib, modulesPath, ... }:

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

  services.openssh.listenAddresses = [ { addr = "0.0.0.0"; port = 22; } ];
  networking.firewall.allowedTCPPorts = [ 22 ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # filesystems.nix already excludes /sys for containers. Extend that logic:
  # the container host manages all remaining pseudo-filesystems, so disable
  # them here to prevent the specialfs activation snippet from trying to
  # remount them via fsconfig() — a syscall blocked in unprivileged containers.
  boot.specialFileSystems = {
    "/dev".enable      = lib.mkForce false;
    "/dev/pts".enable  = lib.mkForce false;
    "/dev/shm".enable  = lib.mkForce false;
    "/proc".enable     = lib.mkForce false;
    "/run".enable      = lib.mkForce false;
    "/run/keys".enable = lib.mkForce false;
  };
}
