{ config, ... }:

{
  imports = [
    ./common.nix
    ./observability-agent.nix
    ../../common/wireguard.nix
  ];

  networking.firewall.enable = true;

  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

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
