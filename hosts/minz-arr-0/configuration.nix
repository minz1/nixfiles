{
  hostName,
  config,
  lib,
  ...
}:

let
  topology = import ../../common/topology.nix;
  node = topology.nodes."${hostName}";
in
{
  imports = [
    ../../modules/services/decypharr.nix
    ../../modules/nixos/rootless-podman.nix
  ];

  networking.hostName = hostName;
  system.stateVersion = "25.11";

  sops.secrets.sonarr_api_key = { };
  sops.secrets.radarr_api_key = { };
  sops.secrets.prowlarr_api_key = { };

  # Derive env-file and container-env formats from the bare API key values.
  # seadexerr_env is gone from sops — both keys it contained come from here.
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
  # DynamicUser service: EnvironmentFile is read by systemd as root before the
  # dynamic UID is allocated, so root:root 0400 is the correct owner/mode.
  sops.templates.prowlarr-env = {
    content = "PROWLARR__AUTH__APIKEY=${config.sops.placeholder.prowlarr_api_key}";
    mode = "0400";
  };
  sops.secrets.zilean_db_password = { };

  # Quadlet containers run as uid 902 (oci); EnvironmentFile is read by Podman
  # before exec, so owner must match the rootless uid.
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

  services.rootless-podman = {
    enable = true;
    user = "oci";
    uid = 902;
  };

  # Shared group — sonarr, radarr, bazarr, decypharr all need /data rw
  users.groups.media = { };
  users.users.sonarr.extraGroups = [ "media" ];
  users.users.radarr.extraGroups = [ "media" ];
  users.users.bazarr.extraGroups = [ "media" ];

  # --- Arr services ---

  services.sonarr = {
    enable = true;
    openFirewall = true;
    settings.server.urlBase = "/sonarr";
    environmentFiles = [ config.sops.templates.sonarr-env.path ];
  };

  services.radarr = {
    enable = true;
    openFirewall = true;
    settings.server.urlBase = "/radarr";
    environmentFiles = [ config.sops.templates.radarr-env.path ];
  };

  services.prowlarr = {
    enable = true;
    openFirewall = true;
    settings.server.urlBase = "/prowlarr";
    environmentFiles = [ config.sops.templates.prowlarr-env.path ];
  };
  systemd.services.prowlarr.serviceConfig = {
    # Recreate the Custom definitions symlink before each start so a nix store
    # hash change after deploy doesn't leave a stale pointer.
    ExecStartPre = "+/bin/sh -c 'mkdir -p /var/lib/private/prowlarr/Definitions && ln -sfT ${../../config/prowlarr/indexers} /var/lib/private/prowlarr/Definitions/Custom'";

    # nixpkgs prowlarr module only adds DynamicUser; add full hardening parity with sonarr.
    CapabilityBoundingSet = "";
    NoNewPrivileges = true;
    ProtectHome = true;
    ProtectClock = true;
    ProtectKernelLogs = true;
    PrivateTmp = true;
    PrivateDevices = true;
    PrivateUsers = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictSUIDSGID = true;
    RemoveIPC = true;
    ProtectHostname = true;
    ProtectProc = "invisible";
    RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
    RestrictNamespaces = true;
    RestrictRealtime = true;
    LockPersonality = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = [ "@system-service" "~@privileged" "~@debug" "~@mount" "@chown" ];
  };

  services.bazarr = {
    enable = true;
    openFirewall = true;
  };

  services.recyclarr.enable = true;

  # sops renders the config with real API keys at runtime, same pattern as
  # sonarr-env / radarr-env. ExecStart override points recyclarr at this
  # file instead of the default /var/lib/recyclarr/config.yml (which the
  # nixpkgs module's genJqSecretsReplacement writes as empty JSON).
  sops.templates.recyclarr-env = {
    content = ''
      SONARR_API_KEY=${config.sops.placeholder.sonarr_api_key}
      RADARR_API_KEY=${config.sops.placeholder.radarr_api_key}
    '';
    owner = "recyclarr";
    mode = "0400";
  };

  systemd.services.recyclarr.serviceConfig = {
    ExecStart = lib.mkForce "${config.services.recyclarr.package}/bin/recyclarr sync --config ${../../config/recyclarr/recyclarr.yml}";
    EnvironmentFile = config.sops.templates.recyclarr-env.path;
  };

  # --- Decypharr ---

  services.decypharr = {
    enable = true;
    mediaPath = "/mnt/decypharr";
    mediaGroup = "media";
    port = node.services.decypharr.port;
  };

  # --- OCI containers (rootless Quadlet, user: oci / uid: 902) ---
  #
  # zilean-pod: shared network namespace for zilean + postgres.
  #   postgres is unreachable from outside the pod; zilean connects via localhost.
  # flaresolverr: Cloudflare bypass proxy for Prowlarr — localhost only
  # seadexerr:    SeaDex anime best-release Torznab — localhost only

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
            volumes = [ "/persist/zilean:/app/data" ];
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
            # 127.0.0.1 is the container's own loopback, not the host.
            # Use the incus_bridge IP so the container can reach arr services.
            environments = {
              SONARR_BASE_URL = "http://${node.networks.incus_bridge.ip}:${toString node.services.sonarr.port}/sonarr/";
              RADARR_BASE_URL = "http://${node.networks.incus_bridge.ip}:${toString node.services.radarr.port}/radarr/";
            };
            environmentFiles = [ config.sops.templates.seadexerr-env.path ];
          };
        };
      };
    };

  # --- NFS server ---
  # Exports /data (library + downloads) and /mnt/decypharr (VFS) to
  # the Incus host (minz-home-nix-0). The host then bind-mounts these into
  # the unprivileged jellyfin container to avoid mount syscall issues.
  services.nfs.server = {
    enable = true;
    exports = ''
      # insecure: required for unprivileged container ports
      # all_squash: mitigates spoofing by forcing all requests to nobody (UID 99)
      /data          10.10.0.1(ro,no_subtree_check,fsid=1,insecure,all_squash,anonuid=99,anongid=99)
      /mnt/decypharr 10.10.0.1(ro,no_subtree_check,fsid=2,insecure,all_squash,anonuid=99,anongid=99)
    '';
  };

  # Ensure NFS server starts after decypharr so it exports the FUSE mount, not the underlying dir.
  systemd.services.nfs-server = {
    wants = [ "decypharr.service" ];
    after = [ "decypharr.service" ];
  };

  # --- Filesystem layout ---
  # Prowlarr custom Cardigann definitions: symlink /var/lib/private/prowlarr/Definitions/Custom
  # to the Nix store so the content is immutable and validated at build time.
  # DynamicUser stores state at /var/lib/private/prowlarr; root can write there.
  systemd.tmpfiles.rules = [
    "d /persist/zilean            0700 oci    oci    -"
    "d /data                     0755 root   root   -"
    "d /data/downloads           0775 root   media  -"
    "d /data/downloads/sonarr    2775 sonarr media  -"
    "d /data/downloads/radarr    2775 radarr media  -"
    "d /data/library             0775 root   media  -"
    "d /data/library/tv          0775 sonarr media  -"
    "d /data/library/movies      0775 radarr media  -"
    "d /var/lib/private/prowlarr/Definitions 0755 root root -"
    "L+ /var/lib/private/prowlarr/Definitions/Custom - - - - ${../../config/prowlarr/indexers}"
  ];

  networking.firewall.allowedTCPPorts = [
    2049 # NFS
    node.services.decypharr.port
    # bazarr omitted: services.bazarr.openFirewall = true already covers it
  ];

  swapDevices = [
    {
      device = "/persist/swapfile";
      size = 2048;
    }
  ];

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/sonarr";
      user = "sonarr";
      group = "sonarr";
      mode = "0700";
    }
    {
      directory = "/var/lib/radarr";
      user = "radarr";
      group = "radarr";
      mode = "0700";
    }
    {
      directory = "/var/lib/private/prowlarr";
      mode = "0700";
    }
    {
      directory = "/var/lib/bazarr";
      user = "bazarr";
      group = "bazarr";
      mode = "0700";
    }
    {
      directory = "/var/lib/decypharr";
      user = "decypharr";
      group = "decypharr";
      mode = "0700";
    }
    {
      directory = "/data";
      mode = "0755";
    }
    {
      directory = "/var/lib/oci";
      user = "oci";
      group = "oci";
      mode = "0750";
    }
  ];
}
