{
  hostName,
  config,
  lib,
  pkgs,
  topology,
  ...
}:

let
  forgejo = topology.nodes."minz-vultr-nix-0";
  forgejoAddr = forgejo.networks.mgmt.ip;
  forgejoPort = 3000;
in
{
  networking.hostName = hostName;
  system.stateVersion = "25.11";

  # No Caddy on this host, but group is needed for ACME cert readability by Alloy/node_exporter.
  users.groups.caddy = { };

  sops.secrets.forgejo_runner_token.mode = "0400";

  sops.secrets.attic_push_token = {
    mode = "0400";
    owner = "podman-runner";
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
          url = "http://${forgejoAddr}:${toString forgejoPort}";
          uuid = "c0787101-0b04-4fc2-8abd-1c28262828ad";
        };
        cache.enabled = false;
        container = {
          docker_host = "unix:///run/user/${toString config.users.users.podman-runner.uid}/podman/podman.sock";
          valid_volumes = [ "/run/secrets/**" ];
          options = lib.concatStringsSep " " [
            "-v ${config.sops.secrets.attic_push_token.path}:/run/secrets/attic_push_token:ro"
          ];
        };
      };
      secrets.server.connections.default.token_url = config.sops.secrets.forgejo_runner_token.path;
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
    serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = lib.mkForce "podman-runner";
      Group = lib.mkForce "podman-runner";
    };
  };

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
