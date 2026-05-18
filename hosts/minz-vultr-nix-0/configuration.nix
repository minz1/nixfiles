{
  config,
  pkgs,
  ...
}:

let
  hostName = "minz-vultr-nix-0";
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

  # EnvironmentFile sets $TOKEN for the register script; sops-nix places this before services start.
  # File must contain "TOKEN=<value>" (KEY=VALUE format, not a raw token string).
  sops.secrets.forgejo_runner_token = {
    mode = "0400";
    restartUnits = [ "gitea-runner-minz_forgejo.service" ];
  };

  # RustFS secrets for the S3-compatible state backend.
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
      device = "/var/lib/swapfile";
      size = 4096;
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
      tokenFile = config.sops.secrets.forgejo_runner_token.path;
      url = "http://${wgAddr}:${toString forgejoPort}";
      labels = [
        "ubuntu-latest:docker://catthehacker/ubuntu:act-latest"
        "node-22:docker://node:22-bookworm"
        "nixos-latest:docker://nixos/nix"
      ];
    };
  };

  systemd.services."gitea-runner-minz_forgejo".serviceConfig = {
    SupplementaryGroups = [ "podman" ];
  };

  # RustFS — S3-compatible object storage for OpenTofu remote state.
  # Binds to all interfaces; the firewall restricts access to the WireGuard
  # interface only (see trustedInterfaces in base.nix).
  # Console is localhost-only; access via SSH tunnel over WG.
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
