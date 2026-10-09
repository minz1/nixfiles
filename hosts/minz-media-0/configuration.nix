{
  config,
  lib,
  pkgs,
  topology,
  node,
  mkHardened,
  ...
}:

let
  mediaIp = node.networks.incus_bridge.ip;
  mediaBackupUnits = "sonarr.service radarr.service prowlarr.service bazarr.service seerr.service jellyfin.service";

  caddyHttpsPort = 443;
  jellyfinPort = 8096;
  mediaAgentPort = 9191;
  seerrPort = 5055;
  sonarrPort = 8989;
  radarrPort = 7878;
  prowlarrPort = 9696;
  bazarrPort = 6767;
  decypharrPort = 8282;
in
{
  imports = [
    ../../modules/nixos/rootless-podman.nix
  ];

  system.stateVersion = "25.11";

  # lxc-container.nix disables programs.fuse, stripping the setuid fusermount3 wrapper rclone needs for non-root FUSE mounts — re-enable it explicitly.
  programs.fuse.enable = lib.mkForce true;

  sops.secrets."media-agent-env".restartUnits = [
    "media-agent.service"
  ];
  sops.secrets.jellyfin_admin_password = { };
  sops.secrets.sonarr_api_key = { };
  sops.secrets.radarr_api_key = { };
  sops.secrets.prowlarr_api_key = { };
  sops.secrets.decypharr_rd_api_key = { };
  sops.secrets.decypharr_rd_download_key = { };
  sops.secrets.decypharr_torbox_api_key = { };
  sops.secrets.decypharr_torbox_download_key = { };
  sops.secrets.decypharr_usenet_username = { };
  sops.secrets.decypharr_usenet_password = { };
  sops.secrets.decypharr_username = { };
  sops.secrets.decypharr_password_hash = { };
  sops.secrets.decypharr_api_token = { };
  sops.secrets.decypharr_secret_key = { };
  sops.secrets.zilean_db_password = { };

  sops.templates.sonarr-env = {
    restartUnits = [
      "sonarr.service"
    ];
    content = "SONARR__AUTH__APIKEY=${config.sops.placeholder.sonarr_api_key}";
    owner = "sonarr";
  };
  sops.templates.radarr-env = {
    restartUnits = [
      "radarr.service"
    ];
    content = "RADARR__AUTH__APIKEY=${config.sops.placeholder.radarr_api_key}";
    owner = "radarr";
  };
  # root:root 0400: EnvironmentFile is read as root before DynamicUser UID is allocated
  sops.templates.prowlarr-env = {
    restartUnits = [
      "prowlarr.service"
    ];
    content = "PROWLARR__AUTH__APIKEY=${config.sops.placeholder.prowlarr_api_key}";
  };
  # Quadlet EnvironmentFile read by Podman before exec; owner must match the rootless UID
  sops.templates.zilean-postgres-env = {
    restartUnits = [
      "zilean-postgres.service"
    ];
    content = "POSTGRES_PASSWORD=${config.sops.placeholder.zilean_db_password}";
    owner = "oci";
  };
  sops.templates.zilean-app-env = {
    restartUnits = [
      "zilean-app.service"
    ];
    content = ''
      POSTGRES_PASSWORD=${config.sops.placeholder.zilean_db_password}
      Zilean__Database__ConnectionString=Host=localhost;Database=zilean;Username=zilean;Password=${config.sops.placeholder.zilean_db_password};Include Error Detail=true;Timeout=30;CommandTimeout=3600;
    '';
    owner = "oci";
  };
  sops.templates.seadexerr-env = {
    content = ''
      SONARR_API_KEY=${config.sops.placeholder.sonarr_api_key}
      RADARR_API_KEY=${config.sops.placeholder.radarr_api_key}
    '';
    owner = "oci";
  };
  sops.templates.decypharr-env = {
    restartUnits = [
      "decypharr.service"
    ];
    content = ''
      DECYPHARR_DEBRIDS__0__API_KEY=${config.sops.placeholder.decypharr_rd_api_key}
      DECYPHARR_DEBRIDS__0__DOWNLOAD_API_KEYS__0=${config.sops.placeholder.decypharr_rd_download_key}
      DECYPHARR_DEBRIDS__1__API_KEY=${config.sops.placeholder.decypharr_torbox_api_key}
      DECYPHARR_DEBRIDS__1__DOWNLOAD_API_KEYS__0=${config.sops.placeholder.decypharr_torbox_download_key}
      DECYPHARR_ARRS__0__TOKEN=${config.sops.placeholder.sonarr_api_key}
      DECYPHARR_ARRS__1__TOKEN=${config.sops.placeholder.radarr_api_key}
      DECYPHARR_USENET__PROVIDERS__0__USERNAME=${config.sops.placeholder.decypharr_usenet_username}
      DECYPHARR_USENET__PROVIDERS__0__PASSWORD=${config.sops.placeholder.decypharr_usenet_password}
      DECYPHARR_SECRET_KEY=${config.sops.placeholder.decypharr_secret_key}
    '';
    owner = "decypharr";
  };

  sops.templates.decypharr-auth-json = {
    restartUnits = [ "decypharr.service" ];
    content = builtins.toJSON {
      username = config.sops.placeholder.decypharr_username;
      password = config.sops.placeholder.decypharr_password_hash;
      api_token = config.sops.placeholder.decypharr_api_token;
    };
    owner = "decypharr";
    mode = "0600";
  };
  sops.templates.recyclarr-env = {
    content = ''
      SONARR_API_KEY=${config.sops.placeholder.sonarr_api_key}
      RADARR_API_KEY=${config.sops.placeholder.radarr_api_key}
    '';
    owner = "recyclarr";
  };

  # Arc A310 DRM passthrough via Incus cgroup allowlist; VAAPI device: /dev/dri/renderD129
  hardware.graphics.enable = true;
  hardware.graphics.extraPackages = with pkgs; [
    intel-media-driver
    intel-compute-runtime
    vpl-gpu-rt # Required for Intel Arc (DG2) QuickSync support
  ];

  # one-time setup wizard completion, so a fresh volume comes up usable without clicking through the UI
  systemd.services.jellyfin-init = {
    description = "Jellyfin one-time setup wizard";
    after = [ "jellyfin.service" ];
    requires = [ "jellyfin.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    path = [
      pkgs.curl
      pkgs.jq
      pkgs.coreutils
    ];

    script = ''
      url="http://127.0.0.1:8096"

      echo "jellyfin-init: waiting for Jellyfin to be ready..."
      for i in {1..60}; do
        if curl -sf "$url/System/Info/Public" > /dev/null 2>&1; then
          if curl -sf "$url/Startup/User" > /dev/null 2>&1 || [ "$(curl -s -o /dev/null -w "%{http_code}" "$url/Startup/User")" = "401" ]; then
            echo "jellyfin-init: Jellyfin is ready."
            break
          fi
        fi
        echo "jellyfin-init: waiting... ($i/60)"
        sleep 5
      done

      completed=$(curl -sf "$url/System/Info/Public" | jq -r '.StartupWizardCompleted')
      if [ "$completed" = "true" ]; then
        echo "jellyfin-init: wizard already completed, nothing to do."
        exit 0
      fi

      password=$(cat "${config.sops.secrets.jellyfin_admin_password.path}")

      echo "jellyfin-init: setting initial configuration..."
      curl -sf -X POST "$url/Startup/Configuration" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
              --arg name "${config.networking.hostName}" \
              '{ServerName: $name, UICulture: "en-US", MetadataCountryCode: "US", PreferredMetadataLanguage: "en"}')"

      echo "jellyfin-init: initializing user creation..."
      curl -sf -X GET "$url/Startup/User" > /dev/null

      echo "jellyfin-init: creating admin user..."
      curl -sf -X POST "$url/Startup/User" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
              --arg name "admin" \
              --arg pass "$password" \
              '{Name: $name, Password: $pass, ConfirmPassword: $pass}')"

      echo "jellyfin-init: configuring remote access..."
      curl -sf -X POST "$url/Startup/RemoteAccess" \
        -H "Content-Type: application/json" \
        -d '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}'

      echo "jellyfin-init: completing wizard..."
      curl -sf -X POST "$url/Startup/Complete"

      echo "jellyfin-init: wizard completed successfully."
    '';
  };

  # jellyfin needs render+video group membership to access /dev/dri/renderD128 in the container.
  users.users.jellyfin.extraGroups = [
    "render"
    "video"
  ];

  services.jellyfin.enable = true;

  services.seerr.enable = true;
  systemd.services.seerr.environment.NODE_EXTRA_CA_CERTS = "/etc/ssl/certs/ca-bundle.crt";

  services.rootless-podman = {
    enable = true;
    user = "oci";
    uid = 902;
  };

  users.groups.media = { };
  users.users.sonarr.extraGroups = [ "media" ];
  users.users.radarr.extraGroups = [ "media" ];
  users.users.bazarr.extraGroups = [ "media" ];

  services.sonarr = {
    enable = true;
    settings.server.urlBase = "/sonarr";
    environmentFiles = [ config.sops.templates.sonarr-env.path ];
  };

  services.radarr = {
    enable = true;
    settings.server.urlBase = "/radarr";
    environmentFiles = [ config.sops.templates.radarr-env.path ];
  };

  services.prowlarr = {
    enable = true;
    settings.server.urlBase = "/prowlarr";
    environmentFiles = [ config.sops.templates.prowlarr-env.path ];
  };
  systemd.services.prowlarr.serviceConfig =
    (mkHardened {
      umask = null;
      extraSystemCallFilter = [ "@chown" ];
    })
    // {
      # no + prefix: runs as DynamicUser so Definitions/ is created with correct ownership
      ExecStartPre = pkgs.writeShellScript "prowlarr-setup-definitions" ''
        mkdir -p /var/lib/prowlarr/Definitions
        ln -sfT ${../../config/prowlarr/indexers} /var/lib/prowlarr/Definitions/Custom
      '';
    };

  services.bazarr.enable = true;

  systemd.services.bazarr.serviceConfig = mkHardened { };

  services.recyclarr.enable = true;

  systemd.services.recyclarr.serviceConfig = {
    ExecStart = lib.mkForce "${config.services.recyclarr.package}/bin/recyclarr sync --config ${../../config/recyclarr/recyclarr.yml}";
    EnvironmentFile = config.sops.templates.recyclarr-env.path;
  };

  services.decypharr = {
    enable = true;
    openFirewall = false;
    extraGroups = [ "media" ];
    mediaGroup = "media";
    authFile = config.sops.templates.decypharr-auth-json.path;

    port = decypharrPort;
    downloadFolder = "/data/downloads";
    maxDownloads = 10;
    removeStalledAfter = "10m";

    dfs = {
      cacheDir = "/var/cache/decypharr";
      diskCacheSize = "85GB";
      chunkSize = "10MB";
    };

    usenet = {
      maxConnections = 15;
      readAhead = "16MB";
      processingTimeout = "10m";
      availabilitySamplePercent = 10;
      importAvailabilitySamplePercent = 20;
    };

    environmentFiles = [ config.sops.templates.decypharr-env.path ];

    settings = {
      categories = [
        "sonarr"
        "radarr"
      ];
      folder_naming = "original_no_ext";
      default_download_action = "symlink";

      # Nothing consumes WebDAV; leaving it on exposes an unauthenticated /webdav route.
      disable_webdav = true;

      mount = {
        type = "dfs";
        mount_path = "/mnt/decypharr";
      };

      debrids = [
        {
          provider = "realdebrid";
          name = "realdebrid";
          rate_limit = "250/minute";
          minimum_free_slot = 1;
          torrents_refresh_interval = "10m";
          download_links_refresh_interval = "40m";
          workers = 100;
          auto_expire_links_after = "3d";
        }
        {
          provider = "torbox";
          name = "torbox";
          rate_limit = "250/minute";
          minimum_free_slot = 1;
          torrents_refresh_interval = "10m";
          download_links_refresh_interval = "40m";
          workers = 100;
          auto_expire_links_after = "3d";
        }
      ];

      arrs = [
        {
          name = "sonarr";
          host = "http://127.0.0.1:8989/sonarr";
          download_uncached = false;
        }
        {
          name = "radarr";
          host = "http://127.0.0.1:7878/radarr";
          download_uncached = false;
        }
      ];

      usenet = {
        providers = [
          {
            host = "news.newshosting.com";
            port = 563;
            max_connections = 30;
            ssl = true;
            priority = 1;
          }
        ];
        disk_buffer_path = "/var/lib/decypharr/usenet/streams";
      };

      allowed_file_types = [
        "3gp"
        "ac3"
        "aiff"
        "alac"
        "amr"
        "ape"
        "asf"
        "asx"
        "avc"
        "avi"
        "bin"
        "bivx"
        "dat"
        "divx"
        "dts"
        "dv"
        "dvr-ms"
        "flac"
        "fli"
        "flv"
        "ifo"
        "m2ts"
        "m2v"
        "m3u"
        "m4a"
        "m4p"
        "m4v"
        "mid"
        "midi"
        "mk3d"
        "mka"
        "mkv"
        "mov"
        "mp2"
        "mp3"
        "mp4"
        "mpa"
        "mpeg"
        "mpg"
        "nrg"
        "nsv"
        "nuv"
        "ogg"
        "ogm"
        "ogv"
        "pva"
        "qt"
        "ra"
        "rm"
        "rmvb"
        "strm"
        "svq3"
        "ts"
        "ty"
        "viv"
        "vob"
        "voc"
        "vp3"
        "wav"
        "webm"
        "wma"
        "wmv"
        "wpl"
        "wtv"
        "wv"
        "xvid"
      ];

      repair = {
        enabled = true;
        source = "arr";
        schedule = "24h";
        workers = 5;
        nntp_connection_percent = 20;
        strategy = "per_entry";
        recheck_interval = "168h";
        auto_repair = true;
      };
    };
  };

  systemd.services.ffprobe-monitor = {
    description = "Monitor and poke stuck ffprobe processes";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = lib.getExe pkgs.ffprobe-monitor;
      Restart = "always";
      RestartSec = "10s";
      # lowest IO / CPU priority so it never interferes with media serving
      IOSchedulingClass = "idle";
      CPUSchedulingPolicy = "idle";
      Nice = 19;
    };
  };

  services.media-agent = {
    enable = true;
    addr = ":${toString mediaAgentPort}";
    environmentFile = config.sops.secrets."media-agent-env".path;
    diskMounts = [
      "/mnt/decypharr"
      "/var/cache/decypharr"
      "/data"
    ];
  };

  # The cache volume root is root:root after creation; fix ownership before decypharr starts.
  systemd.services.decypharr.serviceConfig = {
    ExecStartPre = lib.mkAfter [
      "+${pkgs.coreutils}/bin/chown decypharr:decypharr /var/cache/decypharr"
    ];
    IOWeight = 100;
    OOMScoreAdjust = 500;
  };

  virtualisation.quadlet =
    let
      inherit (config.virtualisation.quadlet) pods containers volumes;
    in
    {
      pods.zilean = {
        rootlessConfig.uid = 902;
        podConfig.publishPorts = [ "127.0.0.1:8181:8181" ];
      };

      volumes.zilean-pg = {
        rootlessConfig.uid = 902;
      };

      containers = {
        zilean-postgres = {
          rootlessConfig.uid = 902;
          containerConfig = {
            image = "docker.io/library/postgres:16-alpine@sha256:cf78e76683b9ca8c5733cbbdce6c9262b45b6767934dd0a95e671f9a0fc20685";
            pod = pods.zilean.ref;
            volumes = [ "${volumes.zilean-pg.ref}:/var/lib/postgresql/data" ];
            environments = {
              POSTGRES_DB = "zilean";
              POSTGRES_USER = "zilean";
            };
            environmentFiles = [ config.sops.templates.zilean-postgres-env.path ];
          };
        };

        zilean-app = {
          rootlessConfig.uid = 902;
          containerConfig = {
            # No upstream release since 2025-04-21 (project looks dormant); pinned to what's been running rather than following an inactive :latest tag.
            image = "ipromknight/zilean:latest@sha256:1b828ac0604235de7adb7757d11c88c1b3bb1a6319071b0c9d99325bc0f9d477";
            pod = pods.zilean.ref;
            volumes = [ "/var/lib/zilean:/app/data" ];
            environmentFiles = [ config.sops.templates.zilean-app-env.path ];
          };
          unitConfig = {
            After = [ containers."zilean-postgres".ref ];
            Requires = [ containers."zilean-postgres".ref ];
          };
        };

        flaresolverr = {
          rootlessConfig.uid = 902;
          containerConfig = {
            image = "ghcr.io/flaresolverr/flaresolverr:latest@sha256:139dfee1c6f89249c8d665d1333a42e8ec74ec0a86bc6bb1c8461e10d3a66a47";
            publishPorts = [ "127.0.0.1:8191:8191" ];
            environments.LOG_LEVEL = "info";
          };
        };

        seadexerr = {
          rootlessConfig.uid = 902;
          containerConfig = {
            image = "ghcr.io/ryder-c/seadexerr:latest@sha256:d0855f27ae7c8fd89c366516b148ef62f9e94f05db30134318ce5faef6426180";
            publishPorts = [ "127.0.0.1:6868:6767" ];
            # incus_bridge IP because 127.0.0.1 is the container's own loopback.
            environments = {
              SONARR_BASE_URL = "http://${mediaIp}:${toString sonarrPort}/sonarr/";
              RADARR_BASE_URL = "http://${mediaIp}:${toString radarrPort}/radarr/";
            };
            environmentFiles = [ config.sops.templates.seadexerr-env.path ];
          };
        };
      };
    };

  systemd.tmpfiles.rules = [
    "d /mnt/decypharr               0775 root   media  -"
    "d /var/lib/zilean               0700 oci    oci    -"
    "d /data                         0755 root   root   -"
    "d /data/downloads/sonarr        2775 sonarr media  -"
    "d /data/downloads/radarr        2775 radarr media  -"
    "d /data/library                 0775 root   media  -"
    "d /data/library/tv              0775 sonarr media  -"
    "d /data/library/movies          0775 radarr media  -"
  ];

  services.caddy = {
    enable = true;
    settings = {
      apps = {
        tls.certificates.load_files = [
          {
            certificate = "/var/lib/acme/minz-media-0.internal/cert.pem";
            key = "/var/lib/acme/minz-media-0.internal/key.pem";
            tags = [ "media" ];
          }
        ];
        http.servers.main = {
          listen = [ ":${toString caddyHttpsPort}" ];
          automatic_https.disable = true;
          tls_connection_policies = [
            { certificate_selection.any_tag = [ "media" ]; }
          ];
          routes = [
            {
              match = [ { host = [ "jellyfin.minz1.com" ]; } ];
              handle = [
                {
                  handler = "reverse_proxy";
                  upstreams = [ { dial = "127.0.0.1:${toString jellyfinPort}"; } ];
                  flush_interval = -1;
                }
              ];
            }
            # Path-specific routes before the seerr catch-all; mediaIp allows direct WireGuard access (e.g. from the Tofu runner at https://10.10.0.7/sonarr).
          ]
          ++
            map
              (app: {
                match = [
                  {
                    host = [
                      "arr.minz1.com"
                      mediaIp
                    ];
                    path = [ "/${app.name}*" ];
                  }
                ];
                handle = [
                  {
                    handler = "reverse_proxy";
                    upstreams = [ { dial = "127.0.0.1:${toString app.port}"; } ];
                  }
                ];
              })
              [
                {
                  name = "sonarr";
                  port = sonarrPort;
                }
                {
                  name = "radarr";
                  port = radarrPort;
                }
                {
                  name = "prowlarr";
                  port = prowlarrPort;
                }
                {
                  name = "bazarr";
                  port = bazarrPort;
                }
              ]
          ++ [
            # radarr v2.3.5 strips base path from provider URL, producing bare /api/v3/* requests
            {
              match = [
                {
                  host = [ mediaIp ];
                  path = [ "/api/v3*" ];
                }
              ];
              handle = [
                {
                  handler = "reverse_proxy";
                  upstreams = [ { dial = "127.0.0.1:${toString radarrPort}"; } ];
                }
              ];
            }
            # catch-all; must follow path routes so /sonarr*, /radarr* etc. don't land here
            {
              match = [
                {
                  host = [
                    "seerr.minz1.com"
                    mediaIp
                  ];
                }
              ];
              handle = [
                {
                  handler = "reverse_proxy";
                  upstreams = [ { dial = "127.0.0.1:${toString seerrPort}"; } ];
                }
              ];
            }
          ];
        };
      };
    };
  };

  networking.firewall.allowedTCPPorts = [
    caddyHttpsPort
  ];

  networking.firewall.extraCommands = ''
    iptables -A nixos-fw -s ${topology.networks.mgmt.subnet} -p tcp --dport ${toString sonarrPort} -j nixos-fw-accept
    iptables -A nixos-fw -s ${topology.networks.mgmt.subnet} -p tcp --dport ${toString radarrPort} -j nixos-fw-accept
    iptables -A nixos-fw -s ${topology.networks.mgmt.subnet} -p tcp --dport ${toString prowlarrPort} -j nixos-fw-accept
    iptables -A nixos-fw -s ${topology.networks.mgmt.subnet} -p tcp --dport ${toString decypharrPort} -j nixos-fw-accept
    iptables -A nixos-fw -s ${topology.networks.incus_bridge.subnet} -p tcp --dport ${toString jellyfinPort} -j nixos-fw-accept
    iptables -A nixos-fw -s ${topology.networks.incus_bridge.subnet} -p tcp --dport ${toString sonarrPort} -j nixos-fw-accept
    iptables -A nixos-fw -s ${topology.networks.incus_bridge.subnet} -p tcp --dport ${toString radarrPort} -j nixos-fw-accept
    iptables -A nixos-fw -s ${topology.networks.incus_bridge.subnet} -p tcp --dport ${toString mediaAgentPort} -j nixos-fw-accept
    iptables -A nixos-fw -s ${topology.networks.incus_bridge.subnet} -p tcp --dport ${toString decypharrPort} -j nixos-fw-accept
  '';

  homelab.endpoints.caddy = {
    ip = mediaIp;
    port = caddyHttpsPort;
  };

  # Config + operational state only — not the media library itself (lives on NFS/decypharr mounts
  # elsewhere) and not decypharr's disposable cache (docs/ops.md). Deliberately excludes zilean's
  # postgres: it's a DMM/IMDb scrape cache the service rebuilds on its own, not user data.
  # The apps keep live SQLite DBs in WAL mode, so they're stopped for the ~30s snapshot; decypharr
  # stays up since it backs the streaming mounts, and its small DB is the one hot copy.
  systemd.services."restic-backups-media-configs".path = [ pkgs.systemd ];
  homelab.backups.targets.media-configs = {
    paths = [
      "/var/lib/sonarr"
      "/var/lib/radarr"
      "/var/lib/private/prowlarr"
      "/var/lib/private/jellyseerr"
      "/var/lib/bazarr"
      "/var/lib/jellyfin"
      "/var/lib/decypharr/db"
    ];
    prepareCommand = "systemctl stop ${mediaBackupUnits}";
    cleanupCommand = "systemctl start ${mediaBackupUnits}";
    timerConfig = {
      OnCalendar = "*-*-* 04:30:00";
      RandomizedDelaySec = "30m";
      Persistent = true;
    };
  };
}
