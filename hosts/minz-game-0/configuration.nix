{
  hostName,
  config,
  pkgs,
  hostEndpoints,
  node,
  mkHardened,
  ...
}:

let
  gameIp = node.networks.incus_bridge.ip;

  gamePort = 25565;
  rconPort = 25575;
  proxyPort = 3128;

  authentikIp = hostEndpoints.minz-authentik-0.authentik.ip;
  authentikPort = hostEndpoints.minz-authentik-0.authentik.port;

  whitelistSyncPort = 8765;

  # subuid-mapped host UID of the JVM's container-internal UID 1000
  minecraftJvmUid = 100000 + 1000 - 1;

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
  sops.secrets.curseforge_api_key = { };
  sops.secrets.velocity_forwarding_secret = { };
  sops.secrets.minecraft_authentik_token = { };
  sops.secrets.minecraft_webhook_token = { };

  sops.templates.mc-env = {
    restartUnits = [
      "atm10.service"
    ];
    content = ''
      RCON_PASSWORD=${config.sops.placeholder.rcon_password}
      CF_API_KEY=${config.sops.placeholder.curseforge_api_key}
    '';
    owner = "oci";
  };

  sops.templates.mc-proxyforge-config = {
    restartUnits = [
      "atm10.service"
    ];
    content = ''
      version = 2.0
      [forwarding]
      enabled = true
      mode = "MODERN"
      secret = "${config.sops.placeholder.velocity_forwarding_secret}"
    '';
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
      WHITELIST_FILE=/persist/atm10/whitelist.json
      WEBHOOK_TOKEN=${config.sops.placeholder.minecraft_webhook_token}
    '';
    owner = "oci";
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
    "d /persist/atm10 0750 oci oci -"
    "a+ /persist/atm10 - - - - user:oci:rwx,user:${toString minecraftJvmUid}:rx,mask::rwx,default:user:oci:rw-,default:mask::rw-"
    # owned by the writer (oci): a root-owned file under an oci-owned dir is an "unsafe path transition" tmpfiles refuses
    "f /persist/atm10/whitelist.json 0640 oci oci - []"
    "a+ /persist/atm10/whitelist.json - - - - user:${toString minecraftJvmUid}:r--"
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
