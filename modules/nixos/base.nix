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

  # NOTE: this causes a build error until hosts/minz-pki-0/root_ca.crt is
  # replaced with the real CA cert from `step ca init`.
  security.pki.certificates = [
    (builtins.readFile ../../hosts/minz-pki-0/root_ca.crt)
  ];

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
