{
  config,
  pkgs,
  lib,
  ...
}:

let
  hostName = "minz-vultr-nix-0";
  topology = (import ../../common/topology.nix).nodes."${hostName}";
  wgAddr = topology.networks.mgmt.ip;
  forgejoPort = topology.services.forgejo.port;
in
{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = hostName;
  system.stateVersion = "23.11";

  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

  services.openssh.listenAddresses = [
    {
      addr = wgAddr;
      port = topology.services.ssh.port;
    }
  ];

  systemd.services.sshd.after = [ "wireguard-wg0.service" ];
  systemd.services.sshd.wants = [ "wireguard-wg0.service" ];

  networking.wireguard.interfaces = import ../../common/wireguard.nix {
    inherit lib;
    hostName = config.networking.hostName;
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
      tokenFile = "/var/lib/secrets/forgejo-runner/token";
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
