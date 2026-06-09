{
  hostName,
  config,
  lib,
  pkgs,
  ...
}:

let
  mkHardened = import ../../modules/lib/hardening.nix { inherit lib; };
  topology = import ../../common/topology.nix;
  node = topology.nodes."${hostName}";
  mediaIp = node.networks.incus_bridge.ip;
  acmeHttpPort = 80;

  caddyHttpsPort = 443;
  jellyfinPort = 8096;
  seerrPort = 5055;
  sonarrPort = 8989;
  radarrPort = 7878;
  prowlarrPort = 9696;
  bazarrPort = 6767;
in
{
  imports = [
    ../../modules/services/jellyfin-init.nix
    ../../modules/services/ffprobe-monitor.nix
    ../../modules/nixos/rootless-podman.nix
  ];

  networking.hostName = hostName;
  system.stateVersion = "25.11";

  sops.secrets.jellyfin_admin_password.mode = "0400";
  sops.secrets.sonarr_api_key = { };
  sops.secrets.radarr_api_key = { };
  sops.secrets.prowlarr_api_key = { };
  sops.secrets.decypharr_rd_api_key = { };
  sops.secrets.decypharr_rd_download_key = { };
  sops.secrets.decypharr_torbox_api_key = { };
  sops.secrets.decypharr_torbox_download_key = { };
  sops.secrets.decypharr_usenet_username = { };
  sops.secrets.decypharr_usenet_password = { };
  sops.secrets.zilean_db_password = { };

  sops.templates.sonarr-env = {
    content = "SONARR__AUTH__APIKEY=${config.sops.placeholder.sonarr_api_key}";
    owner = "sonarr";
    mode = "0400";
  };
  sops.templates.radarr-env = {
    content = "RADARR__AUTH__APIKEY=${config.sops.placeholder.radarr_api_key}";
    owner = "radarr";
    mode = "0400";
  };
  # root:root 0400: EnvironmentFile is read as root before DynamicUser UID is allocated
  sops.templates.prowlarr-env = {
    content = "PROWLARR__AUTH__APIKEY=${config.sops.placeholder.prowlarr_api_key}";
    mode = "0400";
  };
  # Quadlet EnvironmentFile read by Podman before exec; owner must match the rootless UID
  sops.templates.zilean-postgres-env = {
    content = "POSTGRES_PASSWORD=${config.sops.placeholder.zilean_db_password}";
    owner = "oci";
    mode = "0400";
  };
  sops.templates.zilean-app-env = {
    content = ''
      POSTGRES_PASSWORD=${config.sops.placeholder.zilean_db_password}
      Zilean__Database__ConnectionString=Host=localhost;Database=zilean;Username=zilean;Password=${config.sops.placeholder.zilean_db_password};Include Error Detail=true;Timeout=30;CommandTimeout=3600;
    '';
    owner = "oci";
    mode = "0400";
  };
  sops.templates.seadexerr-env = {
    content = ''
      SONARR_API_KEY=${config.sops.placeholder.sonarr_api_key}
      RADARR_API_KEY=${config.sops.placeholder.radarr_api_key}
    '';
    owner = "oci";
    mode = "0400";
  };
  sops.templates.decypharr-env = {
    content = ''
      DECYPHARR_DEBRIDS__0__API_KEY=${config.sops.placeholder.decypharr_rd_api_key}
      DECYPHARR_DEBRIDS__0__DOWNLOAD_API_KEYS__0=${config.sops.placeholder.decypharr_rd_download_key}
      DECYPHARR_DEBRIDS__1__API_KEY=${config.sops.placeholder.decypharr_torbox_api_key}
      DECYPHARR_DEBRIDS__1__DOWNLOAD_API_KEYS__0=${config.sops.placeholder.decypharr_torbox_download_key}
      DECYPHARR_ARRS__0__TOKEN=${config.sops.placeholder.sonarr_api_key}
      DECYPHARR_ARRS__1__TOKEN=${config.sops.placeholder.radarr_api_key}
      DECYPHARR_USENET__PROVIDERS__0__USERNAME=${config.sops.placeholder.decypharr_usenet_username}
      DECYPHARR_USENET__PROVIDERS__0__PASSWORD=${config.sops.placeholder.decypharr_usenet_password}
    '';
    owner = "decypharr";
    mode = "0400";
  };
  sops.templates.recyclarr-env = {
    content = ''
      SONARR_API_KEY=${config.sops.placeholder.sonarr_api_key}
      RADARR_API_KEY=${config.sops.placeholder.radarr_api_key}
    '';
    owner = "recyclarr";
    mode = "0400";
  };

  # Arc A310 DRM passthrough via Incus cgroup allowlist; VAAPI device: /dev/dri/renderD129
  hardware.graphics.enable = true;
  hardware.graphics.extraPackages = with pkgs; [
    intel-media-driver
    intel-compute-runtime
    vpl-gpu-rt # Required for Intel Arc (DG2) QuickSync support
  ];

  services.jellyfin-init = {
    enable = true;
    adminPasswordFile = config.sops.secrets.jellyfin_admin_password.path;
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
    openFirewall = true;
    extraGroups = [ "media" ];
    mediaGroup = "media";
    useAuth = false;

    port = 8282;
    downloadFolder = "/data/downloads";
    maxDownloads = 10;
    removeStalledAfter = "10m";

    rclone = {
      cacheDir = "/var/cache/decypharr";
      vfsCacheMode = "full";
      vfsCacheMaxSize = "85G";
      vfsCacheMaxAge = "168h";
      vfsReadChunkSize = "128M";
      vfsReadChunkSizeLimit = "off";
      vfsReadChunkStreams = 4;
      vfsReadAhead = "256M";
      vfsCachePollInterval = "5m";
      vfsCacheMinFreeSpace = "5G";
      vfsDiskSpaceTotal = "100G";
      bufferSize = "32M";
      transfers = 8;
      asyncRead = true;
      attrTimeout = "1h";
      dirCacheTime = "24h";
    };

    usenet = {
      maxConnections = 15;
      readAhead = "16MB";
      processingTimeout = "10m";
      availabilitySamplePercent = 10;
      maxConcurrentNZB = 2;
    };

    environmentFiles = [ config.sops.templates.decypharr-env.path ];

    settings = {
      categories = [
        "sonarr"
        "radarr"
      ];
      folder_naming = "original_no_ext";
      default_download_action = "symlink";

      mount = {
        type = "rclone";
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

  services.ffprobe-monitor.enable = true;

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
            image = "docker.io/library/postgres:16-alpine";
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
            image = "ipromknight/zilean:latest";
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
            image = "ghcr.io/flaresolverr/flaresolverr:latest";
            publishPorts = [ "127.0.0.1:8191:8191" ];
            environments.LOG_LEVEL = "info";
          };
        };

        seadexerr = {
          rootlessConfig.uid = 902;
          containerConfig = {
            image = "ghcr.io/ryder-c/seadexerr:latest";
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

  systemd.services.caddy.after = lib.mkAfter [ "acme-minz-media-0.internal.service" ];
  systemd.services.caddy.wants = [ "acme-minz-media-0.internal.service" ];

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
            # Path-specific routes before the seerr catch-all; mediaIp allows direct
            # WireGuard access (e.g. from the Tofu runner at https://10.10.0.7/sonarr).
            {
              match = [
                {
                  host = [
                    "arr.minz1.com"
                    mediaIp
                  ];
                  path = [ "/sonarr*" ];
                }
              ];
              handle = [
                {
                  handler = "reverse_proxy";
                  upstreams = [ { dial = "127.0.0.1:${toString sonarrPort}"; } ];
                }
              ];
            }
            {
              match = [
                {
                  host = [
                    "arr.minz1.com"
                    mediaIp
                  ];
                  path = [ "/radarr*" ];
                }
              ];
              handle = [
                {
                  handler = "reverse_proxy";
                  upstreams = [ { dial = "127.0.0.1:${toString radarrPort}"; } ];
                }
              ];
            }
            {
              match = [
                {
                  host = [
                    "arr.minz1.com"
                    mediaIp
                  ];
                  path = [ "/prowlarr*" ];
                }
              ];
              handle = [
                {
                  handler = "reverse_proxy";
                  upstreams = [ { dial = "127.0.0.1:${toString prowlarrPort}"; } ];
                }
              ];
            }
            {
              match = [
                {
                  host = [
                    "arr.minz1.com"
                    mediaIp
                  ];
                  path = [ "/bazarr*" ];
                }
              ];
              handle = [
                {
                  handler = "reverse_proxy";
                  upstreams = [ { dial = "127.0.0.1:${toString bazarrPort}"; } ];
                }
              ];
            }
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
    acmeHttpPort
    caddyHttpsPort
  ];

  networking.firewall.extraCommands = ''
    iptables -A nixos-fw -s ${topology.networks.mgmt.subnet} -p tcp --dport ${toString sonarrPort} -j nixos-fw-accept
    iptables -A nixos-fw -s ${topology.networks.mgmt.subnet} -p tcp --dport ${toString radarrPort} -j nixos-fw-accept
    iptables -A nixos-fw -s ${topology.networks.mgmt.subnet} -p tcp --dport ${toString prowlarrPort} -j nixos-fw-accept
  '';

  homelab.endpoints.caddy = {
    ip = mediaIp;
    port = caddyHttpsPort;
    tls = true;
  };
}
