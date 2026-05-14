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
