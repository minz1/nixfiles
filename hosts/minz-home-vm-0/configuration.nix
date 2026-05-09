{
  config,
  pkgs,
  lib,
  ...
}:

{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "minz-home-vm-0";
  system.stateVersion = "25.11";

  networking.wireguard.interfaces = import ../../common/wireguard.nix {
    inherit lib;
    hostName = config.networking.hostName;
  };

  networking.networkmanager.enable = true;

  services.decypharr = {
    enable = true;
    mediaPath = "/mnt/debrid";
    mediaGroup = "media";
  };

  services.qemuGuest.enable = true;
  services.spice-vdagentd.enable = true;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelPackages = pkgs.linuxPackages_latest;

  users.users.minz1 = {
    description = "Minz One";
    extraGroups = [ "networkmanager" ];
  };

  programs.neovim.defaultEditor = true;
  environment.shellAliases = {
    vi = "nvim";
    vim = "nvim";
  };
}
