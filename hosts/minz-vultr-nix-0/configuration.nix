{
  config,
  pkgs,
  lib,
  ...
}:

let
  sshKeys = (import ../../common/ssh-keys.nix).minz1;
  wgAddr = "10.8.0.1";
in
{
  imports = [
    ./hardware-configuration.nix
  ];

  networking.hostName = "minz-vultr-nix-0";
  system.stateVersion = "23.11";

  users.users.root.openssh.authorizedKeys.keys = sshKeys;
  services.openssh.settings.PermitRootLogin = "no";
  services.openssh.listenAddresses = [
    {
      addr = wgAddr;
      port = 22;
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
        HTTP_PORT = 3000;
        DOMAIN = wgAddr;
        ROOT_URL = "http://${wgAddr}:3000/";
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
      url = "http://${wgAddr}:3000";
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
