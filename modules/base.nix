{ config, lib, ... }:

let
  sshKeys = (import ../common/ssh-keys.nix).minz1;
  topology = import ../common/topology.nix;
  mgmtNetwork = topology.networks.mgmt;
  hostNode = topology.nodes.${config.networking.hostName} or { networks = { }; };
  hasMgmt = hostNode.networks ? mgmt;
in
{
  imports = [ ../common/wireguard.nix ];
  networking.firewall = {
    enable = true;
    allowedUDPPorts = lib.optional hasMgmt mgmtNetwork.listenPort;
    trustedInterfaces = lib.optional hasMgmt mgmtNetwork.interface;
  };

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

  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  systemd.services.sshd.after = lib.mkIf hasMgmt [ "wireguard-${mgmtNetwork.interface}.service" ];
  systemd.services.sshd.wants = lib.mkIf hasMgmt [ "wireguard-${mgmtNetwork.interface}.service" ];
  sops.defaultSopsFile = lib.mkIf hasMgmt (../secrets + "/${config.networking.hostName}.yaml");
  sops.secrets.wg_private = lib.mkIf hasMgmt { mode = "0400"; };

  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = true;
  services.logrotate.checkConfig = false;
  programs.neovim.enable = true;
}
