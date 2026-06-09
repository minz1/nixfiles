{ config, lib, ... }:

let
  mkHardened = import ../lib/hardening.nix { inherit lib; };
in
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

  # Standalone root CA cert file for services (e.g. Caddy client_authentication)
  # that need to reference a specific trust anchor rather than the full system bundle.
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

  # PrivateUsers omitted: drops AmbientCapabilities, breaking port 80/443 binding on
  # hosts where Caddy uses them. CapabilityBoundingSet keeps only the net-bind capability.
  systemd.services.caddy.serviceConfig = lib.mkIf config.services.caddy.enable (mkHardened {
    capabilityBoundingSet = "CAP_NET_BIND_SERVICE";
    privateUsers = false;
  });
}
