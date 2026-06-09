{ config, lib, ... }:

let
  mkHardened = import ../lib/hardening.nix { inherit lib; };
in
{
  imports = [
    ./common.nix
    ./endpoints.nix
    ./observability-agent.nix
    ../../common/wireguard.nix
  ];

  networking.firewall.enable = true;

  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  sops.defaultSopsFile = ../../secrets + "/${config.networking.hostName}.yaml";

  security.pki.certificates = [
    (builtins.readFile ../../hosts/minz-pki-0/root_ca.crt)
  ];

  # explicit file for services (e.g. Caddy client_authentication) that can't use the system PKI bundle
  environment.etc."ssl/internal-ca.crt" = {
    source = ../../hosts/minz-pki-0/root_ca.crt;
    mode = "0444";
  };

  networking.useNetworkd = true;
  networking.useDHCP = false;

  boot.tmp.cleanOnBoot = true;
  services.logrotate.checkConfig = false;

  boot.kernel.sysctl = {
    "kernel.dmesg_restrict" = 1;
    "kernel.kptr_restrict" = 2;
    "net.core.bpf_jit_harden" = 2;
  };

  # privateUsers=false: ambient CAP_NET_BIND_SERVICE requires no user namespace
  systemd.services.caddy.serviceConfig = lib.mkIf config.services.caddy.enable (mkHardened {
    capabilityBoundingSet = "CAP_NET_BIND_SERVICE";
    privateUsers = false;
  });
}
