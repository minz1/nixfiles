{
  config,
  lib,
  pkgs,
  topology,
  ...
}:

let
  mediaAgentPort = 9191;
  decypharrPort = 8282;
in
{
  sops.secrets."media-agent-env".restartUnits = [
    "media-agent.service"
  ];
  sops.secrets.decypharr_rd_api_key = { };
  sops.secrets.decypharr_rd_download_key = { };
  sops.secrets.decypharr_torbox_api_key = { };
  sops.secrets.decypharr_torbox_download_key = { };
  sops.secrets.decypharr_usenet_username = { };
  sops.secrets.decypharr_usenet_password = { };
  sops.secrets.decypharr_torbox_nntp_username = { };
  sops.secrets.decypharr_torbox_nntp_password = { };
  sops.secrets.decypharr_username = { };
  sops.secrets.decypharr_password_hash = { };
  sops.secrets.decypharr_api_token.sopsFile = ../../secrets/shared/decypharr.yaml;
  sops.secrets.decypharr_secret_key = { };

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
      DECYPHARR_USENET__PROVIDERS__1__USERNAME=${config.sops.placeholder.decypharr_torbox_nntp_username}
      DECYPHARR_USENET__PROVIDERS__1__PASSWORD=${config.sops.placeholder.decypharr_torbox_nntp_password}
      DECYPHARR_SECRET_KEY=${config.sops.placeholder.decypharr_secret_key}
      DECYPHARR_API_TOKEN=${config.sops.placeholder.decypharr_api_token}
    '';
    owner = "decypharr";
  };

  sops.templates.decypharr-auth-json = {
    restartUnits = [ "decypharr.service" ];
    content = builtins.toJSON {
      username = config.sops.placeholder.decypharr_username;
      password = config.sops.placeholder.decypharr_password_hash;
    };
    owner = "decypharr";
    mode = "0600";
  };

  services.decypharr = {
    enable = true;
    openFirewall = false;
    extraGroups = [ "media" ];
    mediaGroup = "media";
    authFile = config.sops.templates.decypharr-auth-json.path;

    port = decypharrPort;
    bindAddress = "127.0.0.1";
    downloadFolder = "/data/downloads";
    maxDownloads = 10;
    removeStalledAfter = "2h";

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

      hearsay.participate = false;

      prune = {
        enabled = true;
        mode = "delete";
        schedule = "1h";
        grace = "168h";
        max_per_run = 100;
        roots = [
          "/data/library"
          "/data/downloads"
        ];
      };

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
          auto_expire_links_after = "3d";
        }
        {
          provider = "torbox";
          name = "torbox";
          rate_limit = "250/minute";
          minimum_free_slot = 1;
          torrents_refresh_interval = "10m";
          download_links_refresh_interval = "40m";
          auto_expire_links_after = "3d";
        }
      ];

      arrs = [
        {
          name = "sonarr";
          host = "http://127.0.0.1:8989/sonarr";
          download_uncached = true;
          import_webhook = true;
        }
        {
          name = "radarr";
          host = "http://127.0.0.1:7878/radarr";
          download_uncached = true;
          import_webhook = true;
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
          {
            host = "nntp.torbox.app";
            port = 563;
            max_connections = 10;
            ssl = true;
            priority = 2;
            backup = true;
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

  services.media-agent = {
    enable = true;
    addr = "127.0.0.1:${toString mediaAgentPort}";
    environmentFile = config.sops.secrets."media-agent-env".path;
    diskMounts = [
      "/mnt/decypharr"
      "/var/cache/decypharr"
      "/data"
    ];
  };

  systemd.services.decypharr.stopIfChanged = false;

  # The cache volume root is root:root after creation; fix ownership before decypharr starts.
  systemd.services.decypharr.serviceConfig = {
    ExecStartPre = lib.mkAfter [
      "+${pkgs.coreutils}/bin/chown decypharr:decypharr /var/cache/decypharr"
    ];
    IOWeight = 100;
    OOMScoreAdjust = 500;
  };
}
