{
  hostName,
  config,
  lib,
  pkgs,
  ...
}:

let
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

  sops.templates.forgejo-runner-env = {
    content = "TOKEN=${config.sops.placeholder.forgejo_runner_token}";
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
    owner = config.services.rustfs.user;
    group = config.services.rustfs.group;
    restartUnits = [ "rustfs.service" ];
  };
  sops.secrets.rustfs-secret-key = {
    mode = "0400";
    owner = config.services.rustfs.user;
    group = config.services.rustfs.group;
    restartUnits = [ "rustfs.service" ];
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
      directory = "/var/lib/gitea-runner";
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

  services.gitea-actions-runner = {
    package = pkgs.forgejo-runner;
    instances.minz_forgejo = {
      enable = true;
      name = "minz_forgejo-runner-0";
      tokenFile = config.sops.templates.forgejo-runner-env.path;
      url = "http://${wgAddr}:${toString forgejoPort}";
      labels = [
        "nixos-latest:docker://ghcr.io/catthehacker/ubuntu:act-24.04"
      ];
      settings.cache = {
        enabled = true;
        host = wgAddr;
      };
      settings.container = {
        docker_host = "unix:///run/user/${toString config.users.users.podman-runner.uid}/podman/podman.sock";
        valid_volumes = [ "/run/secrets/**" ];
        options = lib.concatStringsSep " " [
          "-v ${config.sops.secrets.forgejo_deploy_key.path}:/run/secrets/deploy_ssh_key:ro"
          "-v ${config.sops.secrets.incus_client_key.path}:/run/secrets/incus_client_key:ro"
          "-v ${config.sops.templates.tofu-env.path}:/run/secrets/tofu-env:ro"
        ];
      };
    };
  };

  systemd.services."gitea-runner-minz_forgejo" = {
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
    accessKeyFile = config.sops.secrets.rustfs-access-key.path;
    secretKeyFile = config.sops.secrets.rustfs-secret-key.path;
    volumes = "/var/lib/rustfs";
    address = ":9000";
    consoleEnable = true;
    consoleAddress = "127.0.0.1:9001";
    logLevel = "info";
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
      ACCESS_KEY=$(cat ${config.sops.secrets.rustfs-access-key.path})
      SECRET_KEY=$(cat ${config.sops.secrets.rustfs-secret-key.path})
      export AWS_ACCESS_KEY_ID="$ACCESS_KEY"
      export AWS_SECRET_ACCESS_KEY="$SECRET_KEY"

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
