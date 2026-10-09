{ config, lib, pkgs, ... }:

let
  # unreleased upstream fix: 4.2.1 splits records that straddle its read buffer into two syslog lines
  auditWithFgetsFix = pkgs.audit.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      (pkgs.fetchpatch {
        url = "https://github.com/linux-audit/audit-userspace/commit/ac1cf282fa3a860557a963554498fa544dedaeef.patch";
        hash = "sha256-Wq4SbZTltS+8FWYX8zrXSpz1znf4ZdVzPKQramX9n2w=";
      })
    ];
  });
in

{
  imports = [
    ./common.nix
    ./endpoints.nix
    ./observability-agent.nix
    ./backups.nix
    ./binary-cache.nix
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

    "kernel.unprivileged_bpf_disabled" = 1;
    "kernel.perf_event_paranoid" = 3;
    "vm.unprivileged_userfaultfd" = 0;
    "fs.protected_fifos" = 2;
    "fs.protected_regular" = 2;
    "kernel.sysrq" = 144; # sync + reboot only
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.default.accept_redirects" = 0;
    "net.ipv4.conf.all.secure_redirects" = 0;
    "net.ipv4.conf.default.secure_redirects" = 0;
  };

  security.protectKernelImage = true;
  security.forcePageTableIsolation = true;
  systemd.coredump.enable = false;

  # media-0 is an LXC container; kernel audit isn't namespaced there.
  security.auditd.enable = !config.boot.isContainer;
  security.audit = lib.mkIf (!config.boot.isContainer) {
    enable = true;
    rules = [
      "-a exit,always -F arch=b64 -F euid=0 -F auid>=1000 -F auid!=unset -S execve -k privesc"
      "-a exit,always -F arch=b64 -F uid<1000 -F uid!=0 -S execve -k svc-exec"
      "-w /etc/shadow -p wa -k identity"
      "-w /etc/passwd -p wa -k identity"
      "-w /etc/group -p wa -k identity"
      "-w /etc/ssh/sshd_config -p wa -k sshd"
      "-w /etc/sudoers -p wa -k sudoers"
    ];
  };

  # unbounded by default; /var/log is persisted storage
  security.auditd.settings = lib.mkIf (!config.boot.isContainer) {
    max_log_file = 32; # MiB
    max_log_file_action = "rotate";
    num_logs = 5; # 160 MiB ceiling per host
    space_left_action = "syslog";
    admin_space_left_action = "suspend";
  };

  # routes audit events into journald -> existing mTLS Loki pipeline, avoids tailing 0700 audit.log
  security.auditd.plugins.syslog.active = lib.mkIf (!config.boot.isContainer) true;
  security.auditd.package = auditWithFgetsFix;

  # RefuseManualStop blocks restarts; SIGHUP makes auditd stop and respawn every plugin from config
  systemd.services.auditd = lib.mkIf (!config.boot.isContainer) {
    reloadIfChanged = true;
    restartTriggers = [ config.environment.etc."audit/plugins.d/syslog.conf".source ];
    serviceConfig.ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
  };

  # systemd's built-in public resolvers; Incus ACLs drop them anyway whenever a link briefly loses its DNS
  services.resolved.settings.Resolve.FallbackDNS = [ ];

  # default 10000/30s; a nixos-rebuild burst can otherwise silently drop audit records
  services.journald.settings.Journal.RateLimitBurst = 50000;

}
