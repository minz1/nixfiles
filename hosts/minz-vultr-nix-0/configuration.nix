{
  hostName,
  config,
  lib,
  pkgs,
  ...
}:

let
  mkHardened = import ../../modules/lib/hardening.nix { inherit lib; };
  topology = import ../../common/topology.nix;
  node = topology.nodes."${hostName}";
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

  sops.secrets.forgejo_runner_token.mode = "0400";
  sops.secrets.forgejo_deploy_key = {
    mode = "0400";
    owner = "podman-runner";
  };

  sops.secrets.incus_client_key = {
    sopsFile = ../../secrets/incus-client.yaml;
    key = "client_key";
    mode = "0400";
    owner = "podman-runner";
  };

  sops.templates.rustfs-env = {
    content = ''
      RUSTFS_ACCESS_KEY=${config.sops.placeholder.rustfs-access-key}
      RUSTFS_SECRET_KEY=${config.sops.placeholder.rustfs-secret-key}
    '';
    owner = config.services.rustfs.user;
    group = config.services.rustfs.group;
    mode = "0400";
  };

  sops.templates.tofu-env = {
    content = ''
      AWS_ACCESS_KEY_ID=${config.sops.placeholder.rustfs-access-key}
      AWS_SECRET_ACCESS_KEY=${config.sops.placeholder.rustfs-secret-key}
    '';
    owner = "podman-runner";
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

  environment.persistence."/persist".directories = [
    "/var/lib/forgejo"
    "/var/lib/postgresql"
    "/var/lib/rustfs"
    {
      directory = "/var/lib/podman-runner";
      user = "podman-runner";
      group = "podman-runner";
      mode = "0750";
    }
    {
      directory = "/var/lib/forgejo-runner";
      user = "podman-runner";
      group = "podman-runner";
      mode = "0750";
    }
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
    };
  };

  services.forgejo-runner = {
    package = pkgs.forgejo-runner;
    instances.minz_forgejo = {
      enable = true;
      # Reuses the pre-existing runner's identity so it keeps its registration and job history across the gitea-actions-runner -> forgejo-runner module migration, rather than re-registering as a new runner.
      settings = {
        runner.labels = [
          "nixos-latest:docker://ghcr.io/catthehacker/ubuntu:act-24.04@sha256:62d572b92f9f32d3427b6d220ad1f9dca9c7b6ffad37d295425037dbff78abaf"
        ];
        server.connections.default = {
          url = "http://${wgAddr}:${toString forgejoPort}";
          uuid = "f7ef4a1d-816d-482f-a645-153425f66f73";
        };
        cache = {
          enabled = true;
          host = wgAddr;
        };
        container = {
          docker_host = "unix:///run/user/${toString config.users.users.podman-runner.uid}/podman/podman.sock";
          valid_volumes = [ "/run/secrets/**" ];
          options = lib.concatStringsSep " " [
            "-v ${config.sops.secrets.forgejo_deploy_key.path}:/run/secrets/deploy_ssh_key:ro"
            "-v ${config.sops.secrets.incus_client_key.path}:/run/secrets/incus_client_key:ro"
            "-v ${config.sops.templates.tofu-env.path}:/run/secrets/tofu-env:ro"
          ];
        };
      };
      secrets.server.connections.default.token_url = config.sops.secrets.forgejo_runner_token.path;
      # Rootless podman under a dedicated user, not the rootful setup this option targets (module TODO: "Add support for rootless Podman") — avoids the rootful defaults (podman.service ordering, "podman" supplementary group) it would otherwise infer from the ":docker" label.
      runtimes.podman = false;
    };
  };

  # `until=24h` skips a job container/image that might still be under investigation.
  systemd.services.podman-runner-prune = {
    description = "Prune unused Podman images/containers/volumes for the CI runner cache";
    after = [ "user@${toString config.users.users.podman-runner.uid}.service" ];
    path = [ pkgs.podman ];
    serviceConfig = {
      Type = "oneshot";
      User = "podman-runner";
      Group = "podman-runner";
      WorkingDirectory = "/tmp";
      Environment = [
        "HOME=/var/lib/podman-runner"
        "XDG_RUNTIME_DIR=/run/user/${toString config.users.users.podman-runner.uid}"
      ];
    };
    script = ''
      podman container prune -f --filter "until=24h"
      podman image prune -af --filter "until=24h"
      podman volume prune -f
    '';
  };

  systemd.timers.podman-runner-prune = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };

  systemd.services."forgejo-runner-minz_forgejo" = {
    after = [ "user@${toString config.users.users.podman-runner.uid}.service" ];
    wants = [ "user@${toString config.users.users.podman-runner.uid}.service" ];
    serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = lib.mkForce "podman-runner";
      Group = lib.mkForce "podman-runner";
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

  users.manageLingering = true;

  users.users.podman-runner = {
    isSystemUser = true;
    uid = 800;
    group = "podman-runner";
    home = "/var/lib/podman-runner";
    createHome = true;
    linger = true;
    subUidRanges = [
      {
        startUid = 100000;
        count = 65536;
      }
    ];
    subGidRanges = [
      {
        startGid = 100000;
        count = 65536;
      }
    ];
  };
  users.groups.podman-runner = { };

  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    dockerSocket.enable = false;
    defaultNetwork.settings.dns_enabled = true;
    autoPrune = {
      enable = true;
      dates = "weekly";
    };
  };

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
