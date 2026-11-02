{
  config,
  pkgs,
  lib,
  endpoints,
  topology,
  ...
}:

let
  cfg = config.services.forgejo;
  runner = import ../../modules/lib/forgejo-runner.nix { inherit lib; };
  edgeIp = topology.nodes.minz-vultr-nix-1.networks.edge.ip;
  forgejoPort = 3000;

  bootstrap = pkgs.writeShellApplication {
    name = "forgejo-bootstrap";
    runtimeInputs = [
      cfg.package
      config.services.postgresql.package
      pkgs.coreutils
      pkgs.gawk
    ];
    runtimeEnv = {
      FORGEJO_DB = cfg.database.name;
      OIDC_DISCOVERY_URL = "https://auth.minz1.com/application/o/forgejo/.well-known/openid-configuration";
      OIDC_SECRET_FILE = config.sops.secrets.forgejo_oidc_client_secret.path;
      RUNNER_SECRET_FILE = config.sops.templates.forgejo_runner_secret.path;
      RUNNER_SCOPE = "minz1";
      RUNNER_NAME = "minz-runner-0";
    };
    text = builtins.readFile ../../scripts/forgejo-bootstrap.sh;
  };

  forgejoSecret = {
    owner = cfg.user;
    restartUnits = [ "forgejo.service" ];
  };
in
{
  system.stateVersion = "25.11";

  sops.secrets = {
    forgejo_oidc_client_secret = forgejoSecret;
    forgejo_smtp_password = forgejoSecret;
    forgejo_ssh_host_key = forgejoSecret;
    runner_token = forgejoSecret // {
      sopsFile = ../../secrets/shared/forgejo.yaml;
    };
  };
  sops.templates.forgejo_runner_secret = forgejoSecret // {
    content = "${runner.id}${config.sops.placeholder.runner_token}";
  };

  services.postgresql.package = pkgs.postgresql_18;

  services.forgejo = {
    enable = true;
    package = pkgs.forgejo;
    database = {
      type = "postgres";
      createDatabase = true;
    };
    secrets.mailer.PASSWD = config.sops.secrets.forgejo_smtp_password.path;
    settings = {
      server = {
        DOMAIN = "git.minz1.com";
        ROOT_URL = "https://git.minz1.com/";
        HTTP_ADDR = "127.0.0.1";
        HTTP_PORT = forgejoPort;
        START_SSH_SERVER = true;
        SSH_LISTEN_PORT = endpoints.git-ssh.port;
        SSH_SERVER_USE_PROXY_PROTOCOL = true;
        BUILTIN_SSH_SERVER_USER = "git";
        SSH_SERVER_HOST_KEYS = config.sops.secrets.forgejo_ssh_host_key.path;
      };
      service = {
        DISABLE_REGISTRATION = false;
        ALLOW_ONLY_EXTERNAL_REGISTRATION = true;
        SHOW_REGISTRATION_BUTTON = false;
        ENABLE_INTERNAL_SIGNIN = false;
        ENABLE_NOTIFY_MAIL = true;
      };
      openid = {
        ENABLE_OPENID_SIGNIN = false;
        ENABLE_OPENID_SIGNUP = false;
      };
      oauth2_client = {
        ENABLE_AUTO_REGISTRATION = true;
        USERNAME = "preferred_username";
      };
      security = {
        REVERSE_PROXY_TRUSTED_PROXIES = "127.0.0.0/8,::1/128,${edgeIp}/32";
        REVERSE_PROXY_LIMIT = 2;
      };
      session.COOKIE_SECURE = true;
      mailer = {
        ENABLED = true;
        PROTOCOL = "smtp+starttls";
        SMTP_ADDR = "smtp.resend.com";
        SMTP_PORT = 587;
        USER = "resend";
        FROM = "Forgejo <noreply@minz1.com>";
      };
    };
  };

  systemd.services.forgejo.preStart = lib.mkAfter (lib.getExe bootstrap);

  homelab.internalProxy.servers.forgejo = {
    port = endpoints.git.port;
    clientAuth = "require";
    allowedClientNodes = [ "minz-vultr-nix-1" ];
    upstream = forgejoPort;
  };
  # the edge sets X-Forwarded-For from the real peer; without this every client is the edge's IP
  services.caddy.settings.apps.http.servers.forgejo.trusted_proxies = {
    source = "static";
    ranges = [ "${edgeIp}/32" ];
  };

  networking.firewall.allowedTCPPorts = [
    endpoints.git.port
    endpoints.git-ssh.port
  ];

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/forgejo";
      user = "forgejo";
      group = "forgejo";
      mode = "0750";
    }
    {
      directory = "/var/lib/postgresql";
      user = "postgres";
      group = "postgres";
      mode = "0750";
    }
  ];

  # repos/LFS backed up hot; setpriv privilege drop matches minz-authentik-0's target.
  homelab.backups.targets.forgejo = {
    paths = [
      "/var/lib/forgejo"
      "/var/backup/forgejo-db.sql"
    ];
    wants = [ "postgresql.service" ];
    prepareCommand = ''
      mkdir -p /var/backup
      ${pkgs.util-linux}/bin/setpriv --reuid postgres --regid postgres --init-groups -- ${config.services.postgresql.package}/bin/pg_dumpall --clean --if-exists > /var/backup/forgejo-db.sql
    '';
    extraCapabilities = [
      "CAP_SETUID"
      "CAP_SETGID"
    ];
    extraSystemCallFilter = [
      "setuid"
      "setgid"
      "setresuid"
      "setresgid"
      "setreuid"
      "setregid"
      "setgroups"
      "setfsuid"
      "setfsgid"
      "capset"
    ];
  };

  environment.systemPackages = [
    (pkgs.writeShellScriptBin "forgejo-cli" ''
      exec /run/wrappers/bin/sudo -u ${cfg.user} \
        env GITEA_WORK_DIR="${cfg.stateDir}" GITEA_CUSTOM="${cfg.customDir}" \
        ${lib.getExe cfg.package} "$@"
    '')
  ];
}
