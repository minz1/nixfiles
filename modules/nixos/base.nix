{ config, lib, ... }:

{
  imports = [
    ./common.nix
    ./endpoints.nix
    ./observability-agent.nix
    ./backups.nix
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

  # auditd doesn't hot-reload; restart doesn't auto-apply either (RefuseManualStart, needs reboot)
  systemd.services.auditd.restartTriggers = lib.mkIf (!config.boot.isContainer) [
    config.environment.etc."audit/plugins.d/syslog.conf".source
  ];

  # default 10000/30s; a nixos-rebuild burst can otherwise silently drop audit records
  services.journald.extraConfig = "RateLimitBurst=50000";

}
