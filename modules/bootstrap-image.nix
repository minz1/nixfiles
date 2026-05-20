# Bootstrap Image
{
  lib,
  modulesPath,
  ...
}:

let
  sshKeys = (import ../common/ssh-keys.nix).minz1;
in
{
  imports = [
    (modulesPath + "/virtualisation/incus-virtual-machine.nix")
    ./vm-hardware.nix
  ];

  virtualisation.incus.agent.enable = true;

  services.qemuGuest.enable = true;
  services.spice-vdagentd.enable = true;

  networking.hostName = lib.mkDefault "nixos-bootstrap";

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  users.users.minz1 = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = sshKeys;
  };

  nix.settings.trusted-users = [ "minz1" ];
  security.sudo.wheelNeedsPassword = false;

  networking.useDHCP = false;
  systemd.network.enable = true;
  systemd.network.networks."10-eth0" = {
    matchConfig.Name = "en*";
    networkConfig.DHCP = "ipv4";
    linkConfig.RequiredForOnline = "routable";
  };

  services.xserver.enable = false;
  zramSwap.enable = true;
  programs.neovim.enable = true;

  system.stateVersion = "25.11";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = false;
}
