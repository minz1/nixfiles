{
  hostName,
  config,
  pkgs,
  hostEndpoints,
  ...
}:

let
  topology = import ../../common/topology.nix;
  gameIp = topology.nodes.${hostName}.networks.incus_bridge.ip;

  gamePort = 25565;
  rconPort = 25575;
  proxyPort = 3128;

  authentikIp = hostEndpoints.minz-authentik-0.authentik.ip;
  authentikPort = hostEndpoints.minz-authentik-0.authentik.port;

  whitelistSyncScript = pkgs.writeShellScript "minecraft-whitelist-sync" ''
    exec ${pkgs.python3}/bin/python3 ${./whitelist-sync.py} "$@"
  '';

  forwardproxyVersion = "v0.0.0-20260321230143-0aab84dad4fc";

  proxyAllowedHosts = [
    "api.curseforge.com"
    "*.forgecdn.net"
    "api.modrinth.com"
    "cdn.modrinth.com"
    "raw.githubusercontent.com"
    "v.kubejs.com"
    "code.redspace.io"
    "adastra.terrarium.earth"
    "discord.com"
    "*.discord.gg"
    "*.discordapp.com"
    "*.discordapp.net"
    "*.mojang.com"
    "libraries.minecraft.net"
    "api.minecraftservices.com"
    "maven.neoforged.net"
    "repo1.maven.org"
  ];
in
{
  imports = [
    ../../modules/nixos/rootless-podman.nix
  ];

  networking.hostName = hostName;
  system.stateVersion = "25.11";

  networking.firewall.allowedTCPPorts = [ gamePort ];

  networking.nftables.enable = true;

  networking.nftables.tables.container-egress = {
    family = "inet";
    content = ''
      chain output {
        type filter hook output priority filter; policy accept;
        meta skuid ${toString config.services.rootless-podman.uid} tcp dport 443 log prefix "oci-egress-bypass " counter
      }
    '';
  };

  services.caddy = {
    enable = true;
    package = pkgs.caddy.withPlugins {
      plugins = [ "github.com/caddyserver/forwardproxy@${forwardproxyVersion}" ];
      hash = "sha256-k4zJVrhH+6eXFAZwHd3hvXHvk3YLcTcskAlQTE+LecI=";
    };
    settings = {
      logging.logs.default.level = "INFO";
      apps.http.servers.forward_proxy = {
        listen = [ "${gameIp}:${toString proxyPort}" ];
        automatic_https.disable = true;
        logs = { };
        routes = [
          {
            handle = [
              {
                handler = "forward_proxy";
                hide_ip = true;
                hide_via = true;
                allowed_ports = [ 443 ];
                acl = [
                  {
                    subjects = proxyAllowedHosts;
                    allow = true;
                  }
                  {
                    subjects = [ "all" ];
                    allow = false;
                  }
                ];
              }
            ];
          }
        ];
      };
    };
  };

  services.rootless-podman = {
    enable = true;
    user = "oci";
    uid = 902;
  };

  sops.secrets.rcon_password = { };
  sops.secrets.curseforge_api_key = { };
  sops.secrets.velocity_forwarding_secret = { };
  sops.secrets.minecraft_authentik_token = { };

  sops.templates.mc-env = {
    content = ''
      RCON_PASSWORD=${config.sops.placeholder.rcon_password}
      CF_API_KEY=${config.sops.placeholder.curseforge_api_key}
    '';
    owner = "oci";
    mode = "0400";
  };

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

  virtualisation.quadlet.containers.atm10 = {
    rootlessConfig.uid = 902;
    containerConfig = {
      # Digest is pinned; image updates require a deliberate change here (world backup + play-test — a new digest re-resolves the CurseForge modpack).
      image = "docker.io/itzg/minecraft-server:java25@sha256:59feb0a1ef286f20a20560c56adf5b927155bfa842951f5db8b8bbc5a1a3ebde";
      volumes = [ "/persist/atm10:/data" ];
      publishPorts = [
        "${toString gamePort}:${toString gamePort}"
        "${toString rconPort}:${toString rconPort}"
      ];
      environments = {
        EULA = "TRUE";
        MODPACK_PLATFORM = "AUTO_CURSEFORGE";
        CF_SLUG = "all-the-mods-10";
        # Velocity handles Mojang auth; backend runs offline.
        ONLINE_MODE = "FALSE";
        ENABLE_RCON = "TRUE";
        RCON_PORT = toString rconPort;
        MEMORY = "16G";
        MAX_PLAYERS = "10";
        ALLOW_FLIGHT = "TRUE";
        SIMULATION_DISTANCE = "6";
        MAX_TICK_TIME = "-1";
        CURSEFORGE_FILES = "distant-horizons,c2me,discord-integration";
        MODRINTH_PROJECTS = "proxy-compatible-forge,zfastnoise,lithium,achievements-optimizer,servercore,scalablelux";
        PROXY = "host.containers.internal:${toString proxyPort}";
        PROXY_NON_PROXY_HOSTS = "localhost|127.*|10.*|169.254.*";
        MC_IMAGE_HELPER_OPTS = "-Dhttps.proxyHost=host.containers.internal -Dhttps.proxyPort=${toString proxyPort}";
        JVM_OPTS = "-XX:+UseZGC -XX:+UseCompactObjectHeaders -XX:SoftMaxHeapSize=13G -XX:ConcGCThreads=2 -Dhttp.proxyHost=host.containers.internal -Dhttp.proxyPort=${toString proxyPort} -Dhttps.proxyHost=host.containers.internal -Dhttps.proxyPort=${toString proxyPort}";
      };
      environmentFiles = [ config.sops.templates.mc-env.path ];
      # itzg healthcheck fires during modpack download causing false failures.
      podmanArgs = [ "--no-healthcheck" ];
    };
    serviceConfig = {
      # + runs as root regardless of User=oci so we can write into /persist/atm10 before it exists; itzg's entrypoint then chowns /data recursively to UID 1000, making the file writable so proxy-compatible-forge can rewrite it.
      ExecStartPre = "+${pkgs.coreutils}/bin/install -Dm 644 ${config.sops.templates.mc-proxyforge-config.path} /persist/atm10/config/proxy-compatible-forge.toml";
      RestartSec = "30s";
    };
    unitConfig = {
      "X-Restart-Triggers" =
        "${config.sops.templates.mc-env.content} ${config.sops.templates.mc-proxyforge-config.content}";
      After = [ "caddy.service" ];
      Wants = [ "caddy.service" ];
    };
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

  systemd.tmpfiles.rules = [
    # oci (uid 902) owns the data root; container init (UID 0 inside = oci on host) sets up subdirs, then drops to UID 1000 for the Minecraft process.
    "d /persist/atm10 0750 oci oci -"
  ];

  # Excludes are re-buildable/redundant (mods+libraries: CurseForge; simplebackups: the mod's own duplicate backup).
  homelab.backups.targets.atm10-world = {
    paths = [ "/persist/atm10" ];
    exclude = [
      "/persist/atm10/simplebackups"
      "/persist/atm10/mods"
      "/persist/atm10/libraries"
      "/persist/atm10/libraries-integratedscripting"
      "/persist/atm10/kubejs"
    ];
    timerConfig = {
      OnCalendar = "*-*-* 01:30:00";
      RandomizedDelaySec = "30m";
      Persistent = true;
    };
  };

  environment.persistence."/persist".directories = [
    # Avoids re-pulling itzg/minecraft-server on every reboot.
    {
      directory = "/var/lib/oci";
      user = "oci";
      group = "oci";
      mode = "0700";
    }
    {
      directory = "/var/lib/caddy";
      user = "caddy";
      group = "caddy";
      mode = "0700";
    }
  ];
}
