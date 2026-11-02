{
  config,
  lib,
  pkgs,
  ...
}:

let
  runner = import ../../modules/lib/forgejo-runner.nix { inherit lib; };
in
{
  imports = [ ../../modules/nixos/rootless-podman.nix ];

  system.stateVersion = "25.11";

  sops.secrets.runner_token.sopsFile = ../../secrets/shared/forgejo.yaml;
  # the runner's token is the whole registration secret (id + runner_token), same as minz-git-0 registers
  sops.templates.forgejo_runner_secret = {
    content = "${runner.id}${config.sops.placeholder.runner_token}";
    restartUnits = [ "forgejo-runner-minz_forgejo.service" ];
  };

  services.forgejo-runner = {
    package = pkgs.forgejo-runner;
    instances.minz_forgejo = {
      enable = true;
      settings = {
        runner.labels = [
          "nixos-latest:docker://ghcr.io/catthehacker/ubuntu:act-24.04@sha256:62d572b92f9f32d3427b6d220ad1f9dca9c7b6ffad37d295425037dbff78abaf"
        ];
        server.connections.default = {
          url = "https://git.minz1.com";
          uuid = runner.uuidOf runner.id;
        };
        cache.enabled = false;
        # "-": job containers get no podman socket; the daemon finds it via DOCKER_HOST.
        container.docker_host = "-";
      };
      secrets.server.connections.default.token_url = config.sops.templates.forgejo_runner_secret.path;
      # Rootless podman under a dedicated user — same reasoning as the pre-migration setup on vultr-nix-0.
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
    environment.DOCKER_HOST = "unix:///run/user/${toString config.users.users.podman-runner.uid}/podman/podman.sock";
    serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = lib.mkForce "podman-runner";
      Group = lib.mkForce "podman-runner";
    };
  };

  services.rootless-podman = {
    enable = true;
    user = "podman-runner";
    uid = 800;
  };
  virtualisation.podman.dockerCompat = true;

  environment.persistence."/persist".directories = [
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
}
