{
  hostName,
  config,
  pkgs,
  node,
  mkHardened,
  ...
}:

let
  wgAddr = node.networks.mgmt.ip;
  forgejoPort = 3000;
  fwPorts = [
    9000
    9001
  ];
in
{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = hostName;
  system.stateVersion = "23.11";

  systemd.network.networks."20-enp1s0" = {
    matchConfig.Name = "enp1s0";
    networkConfig.DHCP = "ipv4";
    linkConfig.RequiredForOnline = "routable";
  };

  services.openssh.listenAddresses = [
    {
      addr = wgAddr;
      port = 22;
    }
  ];

  sops.templates.rustfs-env = {
    content = ''
      RUSTFS_ACCESS_KEY=${config.sops.placeholder.rustfs-access-key}
      RUSTFS_SECRET_KEY=${config.sops.placeholder.rustfs-secret-key}
    '';
    owner = config.services.rustfs.user;
    group = config.services.rustfs.group;
    mode = "0400";
  };

  sops.secrets.rustfs-access-key = {
    mode = "0400";
    restartUnits = [ "rustfs.service" ];
  };
  sops.secrets.rustfs-secret-key = {
    mode = "0400";
    restartUnits = [ "rustfs.service" ];
  };

  # rclone-conf, not the `rcloneConfig` option — that renders world-readable in the store.
  sops.secrets.b2-key-id.mode = "0400";
  sops.secrets.b2-application-key.mode = "0400";

  sops.templates.rclone-conf = {
    content = ''
      [rustfs]
      type = s3
      provider = Other
      env_auth = false
      access_key_id = ${config.sops.placeholder.rustfs-access-key}
      secret_access_key = ${config.sops.placeholder.rustfs-secret-key}
      endpoint = http://127.0.0.1:9000
      region = us-east-1

      [b2]
      type = b2
      account = ${config.sops.placeholder.b2-key-id}
      key = ${config.sops.placeholder.b2-application-key}
    '';
    mode = "0400";
  };

  swapDevices = [
    {
      device = "/persist/swapfile";
      size = 4096;
    }
  ];

  disko.devices.disk.rustfs = {
    device = node.storage.rustfs_disk;
    content = {
      type = "gpt";
      partitions.data = {
        size = "100%";
        content = {
          type = "filesystem";
          format = "ext4";
          mountpoint = "/var/lib/rustfs";
        };
      };
    };
  };

  environment.persistence."/persist".directories = [
    "/var/lib/forgejo"
    "/var/lib/postgresql"
  ];

  services.forgejo = {
    enable = true;
    database.type = "postgres";
    settings = {
      server = {
        HTTP_ADDR = wgAddr;
        HTTP_PORT = forgejoPort;
        DOMAIN = wgAddr;
        ROOT_URL = "http://${wgAddr}:${toString forgejoPort}/";
      };
      service.DISABLE_REGISTRATION = true;
      security.GLOBAL_TWO_FACTOR_REQUIREMENT = "admin";
    };
  };

  services.rustfs = {
    enable = true;
    environmentFile = config.sops.templates.rustfs-env.path;
    settings = {
      RUSTFS_VOLUMES = "/var/lib/rustfs";
      RUSTFS_ADDRESS = ":9000";
      RUSTFS_CONSOLE_ENABLE = "true";
      RUSTFS_CONSOLE_ADDRESS = "127.0.0.1:9001";
      RUSTFS_LOG_LEVEL = "info";
    };
  };

  systemd.services.rustfs-bucket-setup = {
    description = "Ensure RustFS buckets exist";
    after = [ "rustfs.service" ];
    requires = [ "rustfs.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    environment = {
      AWS_DEFAULT_REGION = "us-east-1";
      AWS_ENDPOINT_URL = "http://127.0.0.1:9000";
    };
    script = ''
      source ${config.sops.templates.rustfs-env.path}
      export AWS_ACCESS_KEY_ID="$RUSTFS_ACCESS_KEY"
      export AWS_SECRET_ACCESS_KEY="$RUSTFS_SECRET_KEY"

      aws=${pkgs.awscli2}/bin/aws

      for i in $(seq 30); do
        $aws s3api list-buckets &>/dev/null && break
        sleep 2
      done

      $aws s3api head-bucket --bucket tofu-state 2>/dev/null \
        || $aws s3api create-bucket --bucket tofu-state

      $aws s3api head-bucket --bucket incus-images 2>/dev/null \
        || $aws s3api create-bucket --bucket incus-images
    '';
  };

  # repos/LFS backed up hot; setpriv privilege drop matches minz-authentik-0's target.
  homelab.backups.targets.forgejo = {
    paths = [
      "/var/lib/forgejo"
      "/var/backup/forgejo-db.sql"
    ];
    prepareCommand = ''
      mkdir -p /var/backup
      ${pkgs.util-linux}/bin/setpriv --reuid postgres --regid postgres --init-groups -- ${config.services.postgresql.package}/bin/pg_dumpall --clean --if-exists > /var/backup/forgejo-db.sql
    '';
    extraCapabilities = [
      "CAP_SETUID"
      "CAP_SETGID"
    ];
    extraSystemCallFilter = [
      "setuid"
      "setgid"
      "setresuid"
      "setresgid"
      "setreuid"
      "setregid"
      "setgroups"
      "setfsuid"
      "setfsgid"
      "capset"
    ];
  };

  # rclone (not restic copy, which would need every host's repo password); no hard-delete.
  systemd.services.b2-mirror = {
    description = "Mirror RustFS backups bucket to Backblaze B2";
    after = [ "rustfs.service" ];
    path = [ pkgs.rclone ];
    serviceConfig = mkHardened { };
    environment.RCLONE_CONFIG = config.sops.templates.rclone-conf.path;
    script = ''
      rclone sync rustfs:backups b2:minz-homelab-backups --checkers 8 --transfers 4
    '';
  };

  systemd.timers.b2-mirror = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 06:00:00";
      RandomizedDelaySec = "30m";
      Persistent = true;
    };
  };

  networking.firewall.allowedTCPPorts = fwPorts ++ [ 80 ];

  # No Caddy on this host, but group is needed for ACME cert readability by Alloy.
  users.groups.caddy = { };

  environment.systemPackages =
    let
      cfg = config.services.forgejo;
      forgejo-cli = pkgs.writeShellScriptBin "forgejo-cli" ''
        exec /run/wrappers/bin/sudo -u ${cfg.user} \
          env GITEA_WORK_DIR="${cfg.stateDir}" GITEA_CUSTOM="${cfg.customDir}" \
          ${pkgs.lib.getExe cfg.package} "$@"
      '';
    in
    [
      forgejo-cli
    ];
}
