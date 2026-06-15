{ hostName, config, lib, pkgs, hostEndpoints, ... }:

let
  topology = import ../../common/topology.nix;
  gamePort = 25565;
  rconPort = 25575;

  authentikIp   = hostEndpoints.minz-authentik-0.authentik.ip;
  authentikPort = hostEndpoints.minz-authentik-0.authentik.port;

  whitelistSyncScript = pkgs.writeShellScript "minecraft-whitelist-sync" ''
    exec ${pkgs.python3}/bin/python3 ${./whitelist-sync.py} "$@"
  '';
in
{
  networking.hostName = hostName;
  system.stateVersion = "25.11";

  networking.firewall.allowedTCPPorts = [ gamePort ];

  # No Caddy on this host, but group is required by common.nix / observability-agent.nix.
  users.groups.caddy = { };

  sops.secrets.rcon_password = { };
  sops.secrets.curseforge_api_key = { };
  sops.secrets.velocity_forwarding_secret = { };
  sops.secrets.minecraft_authentik_token = { };

  sops.templates.mc-env = {
    content = ''
      RCON_PASSWORD=${config.sops.placeholder.rcon_password}
      CF_API_KEY=${config.sops.placeholder.curseforge_api_key}
    '';
    mode = "0400";
  };

  # Installed to /data/config/ before container start so proxy-compatible-forge
  # can verify modern Velocity forwarding on first boot.
  sops.templates.mc-proxyforge-config = {
    content = ''
      version = 2.0
      [forwarding]
      enabled = true
      mode = "MODERN"
      secret = "${config.sops.placeholder.velocity_forwarding_secret}"
    '';
    mode = "0400";
  };

  sops.templates.mc-sync-env = {
    content = ''
      RCON_HOST=127.0.0.1
      RCON_PORT=${toString rconPort}
      RCON_PASSWORD=${config.sops.placeholder.rcon_password}
      AUTHENTIK_URL=https://${authentikIp}:${toString authentikPort}
      AUTHENTIK_TOKEN=${config.sops.placeholder.minecraft_authentik_token}
      WHITELIST_FILE=/persist/atm10/whitelist.json
    '';
    mode = "0400";
  };

  virtualisation.podman = {
    enable = true;
    defaultNetwork.settings.dns_enabled = true;
    autoPrune = {
      enable = true;
      dates = "weekly";
    };
  };

  # Bootstrap: game ACL blocks internet egress. Temporarily allow 443/tcp in
  # tofu/infra/acls.tf for first deploy so itzg can fetch the modpack, then remove.
  virtualisation.oci-containers = {
    backend = "podman";
    containers.atm10 = {
      # Tag is pinned; image updates require a deliberate change here.
      image = "docker.io/itzg/minecraft-server:java25-graalvm";
      autoStart = true;
      volumes = [ "/persist/atm10:/data" ];
      ports = [
        "${toString gamePort}:${toString gamePort}"
        "${toString rconPort}:${toString rconPort}"
      ];
      environment = {
        EULA = "TRUE";
        MODPACK_PLATFORM = "AUTO_CURSEFORGE";
        CF_SLUG = "all-the-mods-10";
        # Velocity handles Mojang auth; backend runs offline.
        ONLINE_MODE = "FALSE";
        ENABLE_RCON = "TRUE";
        RCON_PORT = toString rconPort;
        MEMORY = "10G";
        CURSEFORGE_FILES = "better-sparse-structures,distant-horizons";
        MODRINTH_PROJECTS = "proxy-compatible-forge";
      };
      # RCON_PASSWORD and CF_API_KEY injected via env-file.
      # --no-healthcheck: itzg healthcheck fires during modpack download, causing false failures.
      extraOptions = [
        "--env-file=${config.sops.templates.mc-env.path}"
        "--no-healthcheck"
      ];
    };
  };

  systemd.services."podman-atm10" = {
    serviceConfig = {
      ExecStartPre = [
        "${pkgs.coreutils}/bin/install -Dm 644 ${config.sops.templates.mc-proxyforge-config.path} /persist/atm10/config/proxy-compatible-forge.toml"
      ];
      RestartSec = "30s";
    };
    restartTriggers = [
      config.sops.templates.mc-env.content
      config.sops.templates.mc-proxyforge-config.content
    ];
  };

  systemd.services.minecraft-whitelist-sync = {
    description = "Sync Authentik minecraft users to MC whitelist";
    after = [ "network.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${whitelistSyncScript}";
      EnvironmentFile = config.sops.templates.mc-sync-env.path;
    };
    restartTriggers = [
      config.sops.templates.mc-sync-env.content
    ];
  };

  systemd.timers.minecraft-whitelist-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitActiveSec = "60s";
    };
  };

  environment.persistence."/persist".directories = [
    # Avoids re-pulling itzg/minecraft-server on every reboot.
    {
      directory = "/var/lib/containers";
      user = "root";
      group = "root";
      mode = "0755";
    }
  ];
}
