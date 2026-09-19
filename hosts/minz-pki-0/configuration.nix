{
  config,
  pkgs,
  ...
}:

let
  stepCaPort = 9443;
in
{
  system.stateVersion = "25.11";

  environment.etc."step-ca/certs/root_ca.crt".source = ./root_ca.crt;
  environment.etc."step-ca/certs/intermediate_ca.crt".source = ./intermediate_ca.crt;

  sops.secrets.step_ca_password = {
    owner = "step-ca";
  };

  sops.secrets.step_ca_intermediate_key.owner = "step-ca";

  services.step-ca = {
    enable = true;
    address = "0.0.0.0";
    port = stepCaPort;
    settings = (builtins.fromJSON (builtins.readFile ./ca.json)) // {
      root = "/etc/step-ca/certs/root_ca.crt";
      crt = "/etc/step-ca/certs/intermediate_ca.crt";
      key = config.sops.secrets.step_ca_intermediate_key.path;
      db = {
        type = "badgerv2";
        dataSource = "/var/lib/step-ca/db";
        badgerFileLoadingMode = "";
      };
    };
    intermediatePasswordFile = config.sops.secrets.step_ca_password.path;
  };

  networking.firewall.allowedTCPPorts = [ stepCaPort ];

  # badger isn't safe to snapshot hot, so stop/restart step-ca around the backup.
  homelab.backups.targets.step-ca-db = {
    paths = [ "/var/lib/private/step-ca" ];
    prepareCommand = "systemctl stop step-ca.service";
    cleanupCommand = "systemctl start step-ca.service";
    timerConfig = {
      OnCalendar = "*-*-* 03:00:00";
      RandomizedDelaySec = "30m";
      Persistent = true;
    };
  };

  # its own cert comes from its own CA: don't race step-ca at boot
  systemd.services."acme-minz-pki-0.internal" = {
    after = [ "step-ca.service" ];
    wants = [ "step-ca.service" ];
  };
  systemd.services."acme-order-renew-minz-pki-0.internal" = {
    after = [ "step-ca.service" ];
    wants = [ "step-ca.service" ];
  };

  # backupPrepareCommand/backupCleanupCommand need systemctl on PATH — not there by default.
  systemd.services."restic-backups-step-ca-db".path = [ pkgs.systemd ];

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/private/step-ca";
      mode = "0700";
    }
  ];
}
