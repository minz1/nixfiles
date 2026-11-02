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
  # loopback-only sshd for git; HAProxy on endpoints.git-ssh.port hands it connections with the client's IP
  gitSshdPort = 2223;
  # route-table for replies to spoofed client sources: delivered back over lo to HAProxy
  tproxyTable = 123;

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
    runner_token = forgejoSecret // {
      sopsFile = ../../secrets/shared/forgejo.yaml;
    };
  };
  sops.templates.forgejo_runner_secret = forgejoSecret // {
    content = "${runner.id}${config.sops.placeholder.runner_token}";
  };

  services.postgresql.package = pkgs.postgresql_18;

  # sshd runs `forgejo serv` as this user, so it is Forgejo's run user and the git@ in clone URLs
  users.users.git = {
    isSystemUser = true;
    group = "git";
    home = cfg.stateDir;
    shell = pkgs.bashInteractive;
  };
  users.groups.git = { };

  services.forgejo = {
    enable = true;
    package = pkgs.forgejo;
    user = "git";
    group = "git";
    database = {
      type = "postgres";
      createDatabase = true;
      user = "git";
      name = "git";
    };
    secrets.mailer.PASSWD = config.sops.secrets.forgejo_smtp_password.path;
    settings = {
      server = {
        DOMAIN = "git.minz1.com";
        ROOT_URL = "https://git.minz1.com/";
        HTTP_ADDR = "127.0.0.1";
        HTTP_PORT = forgejoPort;
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

  # Forgejo's OpenSSH setup: its authorized_keys (regenerated every start) forces `forgejo serv` per key
  services.openssh = {
    # appended to vm.nix's 0.0.0.0:22
    listenAddresses = [
      {
        addr = "127.0.0.1";
        port = gitSshdPort;
      }
    ];
    settings.PerSourceMaxStartups = 3;
    extraConfig = ''
      Match User git
        AuthorizedKeysFile %h/.ssh/authorized_keys
        AuthenticationMethods publickey
        KbdInteractiveAuthentication no
        PermitTTY no
        PermitUserRC no
        DisableForwarding yes
      Match LocalPort ${toString gitSshdPort}
        AllowUsers git
      Match LocalPort 22
        DenyUsers git
    '';
  };

  # caddy-l4 on the edge sends PROXY v2; HAProxy connects to sshd with the client's address as source
  services.haproxy = {
    enable = true;
    config = ''
      defaults
        mode tcp
        timeout connect 5s
        timeout client 1h
        timeout server 1h

      frontend git_ssh
        bind :${toString endpoints.git-ssh.port}
        tcp-request connection reject unless { src ${edgeIp} }
        tcp-request connection expect-proxy layer4
        default_backend sshd

      backend sshd
        source 0.0.0.0 usesrc clientip
        server sshd 127.0.0.1:${toString gitSshdPort}
    '';
  };
  systemd.services.haproxy.serviceConfig = {
    # usesrc needs IP_TRANSPARENT; CAP_NET_RAW suffices and can't touch nft/routes like CAP_NET_ADMIN
    AmbientCapabilities = lib.mkForce [ "CAP_NET_RAW" ];
    CapabilityBoundingSet = [ "CAP_NET_RAW" ];
  };
  systemd.network.networks."05-lo" = {
    matchConfig.Name = "lo";
    linkConfig.RequiredForOnline = "no";
    routingPolicyRules = [
      {
        From = "127.0.0.1/32";
        IncomingInterface = "lo";
        IPProtocol = "tcp";
        SourcePort = gitSshdPort;
        Table = tproxyTable;
        Priority = 100;
      }
    ];
    routes = [
      {
        Destination = "0.0.0.0/0";
        Type = "local";
        Table = tproxyTable;
      }
    ];
  };

  networking.firewall.allowedTCPPorts = [
    endpoints.git.port
    endpoints.git-ssh.port
  ];

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/forgejo";
      user = "git";
      group = "git";
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
