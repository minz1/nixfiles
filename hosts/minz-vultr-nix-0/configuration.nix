{
  hostName,
  config,
  pkgs,
  ...
}:

let
  topology = (import ../../common/topology.nix);
  node = topology.nodes."${hostName}";
  wgAddr = node.networks.mgmt.ip;
  forgejoPort = node.services.forgejo.port;
  fwPorts =
    node.services.rustfs.ports or [
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

  services.openssh.listenAddresses = [
    {
      addr = wgAddr;
      port = node.services.ssh.port;
    }
  ];

  sops.secrets.forgejo_runner_token.mode = "0400";
  sops.secrets.forgejo_deploy_key.mode = "0400";

  sops.templates.forgejo-runner-env = {
    content = "TOKEN=${config.sops.placeholder.forgejo_runner_token}";
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
    "/var/lib/containers"
    "/var/lib/private/gitea-runner"
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
        "nixos-latest:docker://nixos/nix"
      ];
      settings.container = {
        # Mount the sops-decrypted deploy key into every job container.
        # CI workflows access it at /run/secrets/deploy_ssh_key.
        options = "-v ${config.sops.secrets.forgejo_deploy_key.path}:/run/secrets/deploy_ssh_key:ro";
      };
    };
  };

  systemd.services."gitea-runner-minz_forgejo".serviceConfig = {
    SupplementaryGroups = [ "podman" ];
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

  networking.firewall.allowedTCPPorts = fwPorts;

  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    dockerSocket.enable = true;
    defaultNetwork.settings.dns_enabled = true;
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
