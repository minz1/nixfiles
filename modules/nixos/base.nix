{ config, lib, ... }:

let
  topology = import ../../common/topology.nix;
  mgmtNetwork = topology.networks.mgmt;
  hostNode = topology.nodes.${config.networking.hostName} or { networks = { }; };
  hasMgmt = hostNode.networks ? mgmt;
in
{
  imports = [
    ./common.nix
    ./observability-agent.nix
    ../../common/wireguard.nix
  ];

  networking.firewall.enable = true;

  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  systemd.services.sshd.after = lib.mkIf hasMgmt [ "wireguard-${mgmtNetwork.interface}.service" ];
  systemd.services.sshd.wants = lib.mkIf hasMgmt [ "wireguard-${mgmtNetwork.interface}.service" ];
  sops.defaultSopsFile = ../../secrets + "/${config.networking.hostName}.yaml";

  networking.useNetworkd = true;
  networking.useDHCP = false;

  boot.tmp.cleanOnBoot = true;
  services.logrotate.checkConfig = false;

  boot.kernel.sysctl = {
    "kernel.dmesg_restrict" = 1;
    "kernel.kptr_restrict" = 2;
    "net.core.bpf_jit_harden" = 2;
  };
}
