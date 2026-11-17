{
  config,
  lib,
  pkgs,
  topology,
  mkHardened,
  ...
}:

let
  lp = topology.contracts.localPorts.minz-media-0;
  hosts = topology.contracts.publicHosts;
  oidc = topology.contracts.oidc;
  issuer = app: "https://${hosts.auth}/application/o/${app}/";
  readyDir = "/run/books-ready";
  fingerprintDir = "/var/lib/books-bootstrap";
  secret = name: config.sops.secrets.${name}.path;

  booksReady = pkgs.writeShellApplication {
    name = "books-volume-ready";
    runtimeInputs = [
      pkgs.util-linux
      pkgs.coreutils
    ];
    text = ''
      root="''${1:-/data/books}"
      mountpoint -q "$root"
      install -d -o oci -g media -m 2775 "$root" "$root/ebooks" "$root/audiobooks"
    '';
  };

  mkBootstrap =
    name:
    pkgs.writeShellApplication {
      name = "${name}-bootstrap";
      runtimeInputs = with pkgs; [
        coreutils
        curl
        jq
        gawk
        systemd
      ];
      text = builtins.readFile ../../scripts/${name}-bootstrap.sh;
    };

  invalidate = app: "+${pkgs.coreutils}/bin/rm -f ${readyDir}/${app}";

  bootstrapService = app: unit: env: {
    description = "Reconcile ${app} settings and open public access";
    after = [ unit ];
    partOf = [ unit ];
    wantedBy = [ unit ];
    environment = env // {
      READY_DIR = readyDir;
      FINGERPRINT_DIR = fingerprintDir;
    };
    unitConfig = {
      StartLimitIntervalSec = 600;
      StartLimitBurst = 5;
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${mkBootstrap app}/bin/${app}-bootstrap";
      Restart = "on-failure";
      RestartSec = "30s";
      StateDirectory = "books-bootstrap";
      StateDirectoryMode = "0700";
      UMask = "0077";
    };
  };

  binderyImage = "ghcr.io/vavallee/bindery:v1.51.1@sha256:c22516f3ebe69239c09021cc232765944737dfd1c5c77fa18a2213a87d65ddb9";
in
{
  users.users.oci.extraGroups = [ "media" ];
  users.users.audiobookshelf.extraGroups = [ "media" ];

  systemd.tmpfiles.rules = [
    "d /data/downloads/bindery 2770 decypharr media 14d"
    "d ${readyDir} 0755 root root -"
    "d /var/lib/bindery 0700 oci oci -"
  ];

  systemd.services.books-volume-ready = {
    description = "Check the books volume is mounted and prepare its folders";
    wantedBy = [ "multi-user.target" ];
    unitConfig.RequiresMountsFor = [ "/data/books" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${booksReady}/bin/books-volume-ready /data/books";
    };
  };

  sops.secrets = {
    audiobookshelf_oidc_client_secret = {
      sopsFile = ../../secrets/shared/audiobookshelf.yaml;
      restartUnits = [ "audiobookshelf-bootstrap.service" ];
    };
    audiobookshelf_root_password = {
      sopsFile = ../../secrets/shared/audiobookshelf.yaml;
      restartUnits = [ "audiobookshelf-bootstrap.service" ];
    };
    bindery_api_key = {
      sopsFile = ../../secrets/shared/bindery.yaml;
      restartUnits = [ "bindery.service" ];
    };
    bindery_oidc_client_secret = {
      sopsFile = ../../secrets/shared/bindery.yaml;
      restartUnits = [ "bindery-bootstrap.service" ];
    };
    bindery_ntfy_password = {
      sopsFile = ../../secrets/shared/bindery.yaml;
      restartUnits = [ "bindery-bootstrap.service" ];
    };
    decypharr_api_token.restartUnits = [ "bindery-bootstrap.service" ];
    prowlarr_api_key.restartUnits = [ "bindery-bootstrap.service" ];
  };

  sops.templates.bindery-env = {
    restartUnits = [ "bindery.service" ];
    content = "BINDERY_API_KEY=${config.sops.placeholder.bindery_api_key}";
    owner = "oci";
  };

  services.audiobookshelf = {
    enable = true;
    host = "127.0.0.1";
    port = lp.audiobookshelf.port;
  };

  systemd.services.audiobookshelf = {
    requires = [ "books-volume-ready.service" ];
    after = [ "books-volume-ready.service" ];
    environment.ROUTER_BASE_PATH = "";
    serviceConfig = mkHardened { privateUsers = false; } // {
      ExecStartPre = [ (invalidate "audiobookshelf") ];
      ExecStopPost = [ (invalidate "audiobookshelf") ];
      ReadOnlyPaths = [ "/data/books" ];
    };
  };

  systemd.services.audiobookshelf-bootstrap =
    bootstrapService "audiobookshelf" "audiobookshelf.service"
      {
        ABS_URL = "http://127.0.0.1:${toString lp.audiobookshelf.port}";
        OIDC_DISCOVERY_URL = "${issuer "audiobookshelf"}.well-known/openid-configuration";
        OIDC_CLIENT_ID = oidc.audiobookshelf.clientId;
        OIDC_SECRET_FILE = secret "audiobookshelf_oidc_client_secret";
        ROOT_PASSWORD_FILE = secret "audiobookshelf_root_password";
        LIBRARY_EBOOKS = "/data/books/ebooks";
        LIBRARY_AUDIOBOOKS = "/data/books/audiobooks";
      };

  virtualisation.containers.containersConf.settings.engine.runtime = "crun";

  virtualisation.quadlet.containers.bindery = {
    rootlessConfig.uid = 902;
    unitConfig = {
      Requires = [ "books-volume-ready.service" ];
      After = [ "books-volume-ready.service" ];
    };
    serviceConfig = {
      ExecStartPre = [
        (invalidate "bindery")
        "${pkgs.writeShellScript "bindery-reset-api-key" ''
          db=/var/lib/bindery/bindery.db
          if [ -f "$db" ]; then
            ${lib.getExe pkgs.sqlite} "$db" "DELETE FROM settings WHERE key = 'auth.api_key';"
          fi
        ''}"
      ];
      ExecStopPost = [ (invalidate "bindery") ];
    };
    containerConfig = {
      image = binderyImage;
      publishPorts = [ "127.0.0.1:${toString lp.bindery.port}:8787" ];
      userns = "keep-id:uid=65532,gid=65532";
      addGroups = [ "keep-groups" ];
      networks = [ "pasta:-T,${toString lp.prowlarr.port},-T,${toString lp.decypharr.port}" ];
      volumes = [
        "/var/lib/bindery:/config"
        "/data/books:/data/books"
        "/data/downloads/bindery:/data/downloads/bindery"
      ];
      environments = {
        BINDERY_OIDC_DEFAULT_ROLE = "requester";
        BINDERY_OIDC_ADMIN_GROUP = "arr-admins";
        BINDERY_OIDC_GROUP_CLAIM = "groups";
        BINDERY_LOCAL_AUTH_ENABLED = "false";
        BINDERY_DIR_MODE = "755";
        BINDERY_TELEMETRY_DISABLED = "true";
        BINDERY_DOWNLOAD_ALLOW_LOOPBACK = "1";
        BINDERY_DOWNLOAD_DIR = "/data/downloads/bindery";
        BINDERY_LIBRARY_DIR = "/data/books/ebooks";
        BINDERY_AUDIOBOOK_DIR = "/data/books/audiobooks";
        BINDERY_OIDC_REDIRECT_BASE_URL = "https://${hosts.bindery}";
        BINDERY_ALLOWED_HOSTS = hosts.bindery;
      };
      environmentFiles = [ config.sops.templates.bindery-env.path ];
    };
  };

  systemd.services.bindery-bootstrap = bootstrapService "bindery" "bindery.service" {
    BINDERY_URL = "http://127.0.0.1:${toString lp.bindery.port}";
    API_KEY_FILE = secret "bindery_api_key";
    OIDC_ISSUER = issuer "bindery";
    OIDC_CLIENT_ID = oidc.bindery.clientId;
    OIDC_SECRET_FILE = secret "bindery_oidc_client_secret";
    PROWLARR_URL = "http://127.0.0.1:${toString lp.prowlarr.port}${lp.prowlarr.urlBase}";
    PROWLARR_KEY_FILE = secret "prowlarr_api_key";
    DECYPHARR_HOST = "127.0.0.1";
    DECYPHARR_PORT = toString lp.decypharr.port;
    DECYPHARR_TOKEN_FILE = secret "decypharr_api_token";
    NTFY_URL = "https://${hosts.ntfy}";
    NTFY_TOPIC = "books-requests";
    NTFY_USER = "bindery";
    NTFY_PASSWORD_FILE = secret "bindery_ntfy_password";
  };
}
