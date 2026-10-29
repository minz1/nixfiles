{
  hostName,
  config,
  lib,
  pkgs,
  endpoints,
  node,
  topology,
  mkHardened,
  ...
}:

let
  gameIp = node.networks.incus_bridge.ip;

  gamePort = topology.services.minecraft.port;
  rconPort = 25575;
  proxyPort = 3128;

  authentikIp = endpoints.authentik.ip;
  authentikPort = endpoints.authentik.port;

  whitelistSyncPort = 8765;

  # subuid-mapped host UID of the JVM's container-internal UID 1000
  minecraftJvmUid = 100000 + 1000 - 1;

  forwardproxyVersion = "v0.0.0-20260321230143-0aab84dad4fc";

  proxyAllowedHosts = [
    "api.modrinth.com"
    "cdn.modrinth.com"
    "raw.githubusercontent.com"
    "meta.fabricmc.net"
    "maven.fabricmc.net"
    "discord.com"
    "*.discord.gg"
    "*.discordapp.com"
    "*.discordapp.net"
    "*.mojang.com"
    "libraries.minecraft.net"
    "api.minecraftservices.com"
    "playerdb.co"
    "repo1.maven.org"
  ];

  # Modrinth version IDs, pinned: bumps are deliberate (world backup + join test).
  modrinthProjects = [
    "fabric-api:LEklt8GT"
    "fabricproxy-lite:CsEpiziv"
    "lithium:xS0Q8LSi"
    "ferrite-core:d5ddUdiB"
    "krypton:UugdIYJw"
    "c2me-fabric:gKKkuSYc"
    "scalablelux:g4eqNSKd"
    "zfastnoise:cCGI5KLE"
    "zconfig:tsgt79sG"
    "structure-layout-optimizer:crWm7jXS"
    "resourceful-config:t3odHyFJ"
    "spark:e3hsPc1o"
    "chunky:4Eotm6ov"
    "distanthorizons:TGgEbP9A"
    "ledger:pxv5cN0d"
    "fabric-language-kotlin:SKW1BTL3"
    "discord-mc-chat:49RyYYsL"
    "datapack:terralith:fqnsIp6d"
    "datapack:terratonic:RUBbKGx8"
    "datapack:matcha-flavoured:IlPSTNOv"
  ];
in
{
  imports = [
    ../../modules/nixos/rootless-podman.nix
  ];

  system.stateVersion = "25.11";

  networking.firewall.allowedTCPPorts = [
    gamePort
    443
  ];

  networking.nftables.enable = true;

  networking.nftables.tables.container-egress = {
    family = "inet";
    content = ''
      # Detective, not preventive: policy accept. The discord-integration mod holds a raw WSS
      # connection to Discord's gateway, which the JVM's HTTP proxy settings don't cover (~70/day,
      # all Cloudflare 162.159.13x.x). Dropping here would break it; the ACL still bounds the rest.
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
      hash = "sha256-qNa/T0LbHejTwUJQk1qyB4bbxfZGy9AzPyzO4M7mUCo=";
    };
    settings = {
      logging.logs.default.level = "INFO";
      apps = {
        tls.certificates.load_files = [
          {
            certificate = "/var/lib/acme/${hostName}.internal/cert.pem";
            key = "/var/lib/acme/${hostName}.internal/key.pem";
            tags = [ "game" ];
          }
        ];
        http.servers.forward_proxy = {
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
        http.servers.webhook = {
          listen = [ "${gameIp}:443" ];
          automatic_https.disable = true;
          strict_sni_host = false;
          tls_connection_policies = [ { certificate_selection.any_tag = [ "game" ]; } ];
          routes = [
            {
              match = [
                {
                  not = [
                    { remote_ip.ranges = [ "${authentikIp}/32" ]; }
                  ];
                }
              ];
              handle = [
                {
                  handler = "static_response";
                  status_code = 403;
                }
              ];
            }
            {
              handle = [
                {
                  handler = "reverse_proxy";
                  upstreams = [ { dial = "127.0.0.1:${toString whitelistSyncPort}"; } ];
                  headers.request.set."Host" = [ "{http.request.host}" ];
                }
              ];
            }
          ];
        };
      };
    };
  };

  services.rootless-podman = {
    enable = true;
    user = "oci";
    uid = 902;
  };

  sops.secrets.rcon_password = { };
  sops.secrets.discord_bot_token = { };
  sops.secrets.velocity_forwarding_secret = { };
  sops.secrets.minecraft_authentik_token = { };
  sops.secrets.minecraft_webhook_token.sopsFile = ../../secrets/shared/minecraft.yaml;

  sops.templates.mc-env = {
    restartUnits = [
      "vanilla.service"
    ];
    content = ''
      RCON_PASSWORD=${config.sops.placeholder.rcon_password}
      FABRIC_PROXY_SECRET=${config.sops.placeholder.velocity_forwarding_secret}
    '';
    owner = "oci";
  };

  sops.templates.mc-discord-config = {
    restartUnits = [
      "vanilla.service"
    ];
    content = builtins.toJSON {
      generic = {
        botToken = config.sops.placeholder.discord_bot_token;
        channelId = "1516412559727792218";
      };
    };
  };

  sops.templates.whitelist-sync-env = {
    restartUnits = [
      "minecraft-whitelist-sync.service"
    ];
    content = ''
      RCON_HOST=127.0.0.1
      RCON_PORT=${toString rconPort}
      RCON_PASSWORD=${config.sops.placeholder.rcon_password}
      AUTHENTIK_URL=https://${authentikIp}:${toString authentikPort}
      AUTHENTIK_TOKEN=${config.sops.placeholder.minecraft_authentik_token}
      AUTHENTIK_CLIENT_CERT=/var/lib/acme/${hostName}.internal/cert.pem
      AUTHENTIK_CLIENT_KEY=/var/lib/acme/${hostName}.internal/key.pem
      WHITELIST_FILE=/persist/vanilla/whitelist.json
      WEBHOOK_TOKEN=${config.sops.placeholder.minecraft_webhook_token}
    '';
    owner = "oci";
  };

  virtualisation.quadlet.containers.vanilla = {
    rootlessConfig.uid = 902;
    containerConfig = {
      # Digest is pinned; image updates require a deliberate change here (world backup + join test).
      image = "docker.io/itzg/minecraft-server:java25@sha256:3168dfa30c35fa1f99b8edde120f934a03ee780fcf905f450a1dbd9551d719f5";
      volumes = [ "/persist/vanilla:/data" ];
      publishPorts = [
        "${toString gamePort}:${toString gamePort}"
        "${toString rconPort}:${toString rconPort}"
      ];
      environments = {
        EULA = "TRUE";
        TYPE = "FABRIC";
        VERSION = "26.3";
        FABRIC_LOADER_VERSION = "0.19.5";
        MODRINTH_PROJECTS = lib.concatStringsSep "," modrinthProjects;
        # Matcha's datapack needs its resource pack; clients fetch it from Modrinth on join.
        RESOURCE_PACK = "https://cdn.modrinth.com/data/QI0EmgZ1/versions/leNTHiGm/MFRP_1_12_7_26_3.zip";
        RESOURCE_PACK_SHA1 = "6982ab0a3659e27759d55fc389f7817ee1080f99";
        RESOURCE_PACK_ENFORCE = "TRUE";
        # Velocity handles Mojang auth; FabricProxy-Lite rejects logins without the forwarding secret.
        ONLINE_MODE = "FALSE";
        ENABLE_WHITELIST = "TRUE";
        OPS = "minz1";
        ENABLE_RCON = "TRUE";
        RCON_PORT = toString rconPort;
        MOTD = "minz1's Minecraft Server";
        DIFFICULTY = "normal";
        MEMORY = "8G";
        MAX_PLAYERS = "10";
        SIMULATION_DISTANCE = "6";
        MAX_TICK_TIME = "-1";
        PROXY = "host.containers.internal:${toString proxyPort}";
        PROXY_NON_PROXY_HOSTS = "localhost|127.*|10.*|169.254.*";
        MC_IMAGE_HELPER_OPTS = "-Dhttps.proxyHost=host.containers.internal -Dhttps.proxyPort=${toString proxyPort}";
        JVM_OPTS = "-XX:+UseZGC -XX:+UseCompactObjectHeaders -XX:SoftMaxHeapSize=7G -XX:ConcGCThreads=2 -Dhttp.proxyHost=host.containers.internal -Dhttp.proxyPort=${toString proxyPort} -Dhttps.proxyHost=host.containers.internal -Dhttps.proxyPort=${toString proxyPort}";
      };
      environmentFiles = [ config.sops.templates.mc-env.path ];
      # itzg healthcheck fires during mod download causing false failures.
      podmanArgs = [ "--no-healthcheck" ];
    };
    serviceConfig = {
      # + runs as root; the JVM's UID must own config/ or mods can't write their configs.
      ExecStartPre = [
        "+${pkgs.coreutils}/bin/install -d -o ${toString minecraftJvmUid} -g ${toString minecraftJvmUid} -m 750 /persist/vanilla/config"
        "+${pkgs.coreutils}/bin/install -o ${toString minecraftJvmUid} -g ${toString minecraftJvmUid} -m 600 ${config.sops.templates.mc-discord-config.path} /persist/vanilla/config/discord-mc-chat.json"
      ];
      RestartSec = "30s";
    };
    unitConfig = {
      After = [ "caddy.service" ];
      Wants = [ "caddy.service" ];
    };
  };

  services.minecraft-whitelist-sync = {
    enable = true;
    listenAddr = "127.0.0.1:${toString whitelistSyncPort}";
    environmentFile = config.sops.templates.whitelist-sync-env.path;
    extraServiceConfig = mkHardened { privateUsers = false; } // {
      User = "oci";
      Group = "oci";
      SupplementaryGroups = [ "caddy" ];
    };
  };

  systemd.services.minecraft-whitelist-sync = {
    after = [ "acme-${hostName}.internal.service" ];
    wants = [ "acme-${hostName}.internal.service" ];
  };

  security.acme.certs."${hostName}.internal".reloadServices = [ "minecraft-whitelist-sync.service" ];

  systemd.tmpfiles.rules = [
    # ACLs, not chown: itzg's entrypoint reclaims /data's ownership on every container start
    "d /persist/vanilla 0750 oci oci -"
    "a+ /persist/vanilla - - - - user:oci:rwx,user:${toString minecraftJvmUid}:rx,mask::rwx,default:user:oci:rw-,default:mask::rw-"
    # owned by the writer (oci): a root-owned file under an oci-owned dir is an "unsafe path transition" tmpfiles refuses
    "f /persist/vanilla/whitelist.json 0640 oci oci - []"
    # named oci entry: itzg chowns the file to the JVM on start, so ownership alone doesn't keep the sync's write access
    "a+ /persist/vanilla/whitelist.json - - - - user:oci:rw-,user:${toString minecraftJvmUid}:r--,mask::rw-"
  ];

  # Excludes are re-downloadable on start (Modrinth, Fabric, Mojang).
  homelab.backups.targets.vanilla-world = {
    paths = [ "/persist/vanilla" ];
    exclude = [
      "/persist/vanilla/mods"
      "/persist/vanilla/libraries"
      "/persist/vanilla/versions"
      "/persist/vanilla/.fabric"
    ];
    # Pause autosave and flush so restic reads a consistent world; a stopped server isn't writing, so
    # an unreachable RCON just means back up as-is. Cleanup runs even if the backup fails.
    prepareCommand = ''
      MCRCON_PASS=$(cat ${config.sops.secrets.rcon_password.path}) \
        ${pkgs.mcrcon}/bin/mcrcon -H 127.0.0.1 -P ${toString rconPort} "save-off" "save-all flush" \
        || echo "RCON unreachable; backing up without pausing saves"
    '';
    cleanupCommand = ''
      MCRCON_PASS=$(cat ${config.sops.secrets.rcon_password.path}) \
        ${pkgs.mcrcon}/bin/mcrcon -H 127.0.0.1 -P ${toString rconPort} "save-on" || true
    '';
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
  ];
}
