{ config, lib, ... }:

let
  topology = import ../common/topology.nix;
  mgmtNetwork = topology.networks.mgmt;
  hostNode = topology.nodes.${config.networking.hostName} or { networks = { }; };
  hasMgmt = hostNode.networks ? mgmt;
in
{
  imports = [
    ./common.nix
    ../common/wireguard.nix
  ];

  networking.firewall = {
    enable = true;
    allowedUDPPorts = lib.optional hasMgmt mgmtNetwork.listenPort;
    trustedInterfaces = lib.optional hasMgmt mgmtNetwork.interface;
  };

  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  systemd.services.sshd.after = lib.mkIf hasMgmt [ "wireguard-${mgmtNetwork.interface}.service" ];
  systemd.services.sshd.wants = lib.mkIf hasMgmt [ "wireguard-${mgmtNetwork.interface}.service" ];
  sops.defaultSopsFile = lib.mkIf hasMgmt (../secrets + "/${config.networking.hostName}.yaml");
  sops.secrets.wg_private = lib.mkIf hasMgmt { mode = "0400"; };

  boot.tmp.cleanOnBoot = true;
  services.logrotate.checkConfig = false;
}
