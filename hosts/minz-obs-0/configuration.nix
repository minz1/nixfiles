{
  config,
  lib,
  pkgs,
  topology,
  fleet,
  node,
  mkHardened,
  ...
}:

let
  obsIp = node.networks.incus_bridge.ip;

  victoriaPort = 9090;
  lokiPort = 3100;
  lokiHttpsPort = topology.services.loki.port;
  grafanaPort = 3000;
  grafanaHttpsPort = topology.services.grafana.port;
  blackboxPort = 9115;
  adguardExporterPort = 9618;
  certDir = "/var/lib/acme/minz-obs-0.internal";

  mtlsClient = {
    ca_file = "/etc/ssl/internal-ca.crt";
    cert_file = "${certDir}/fullchain.pem";
    key_file = "${certDir}/key.pem";
  };
  nixosNodes = lib.filterAttrs (_: n: n.kind != "device") topology.nodes;
  nodeExporterTargets = lib.mapAttrsToList (
    _: n:
    let
      ip = if n.networks ? incus_bridge then n.networks.incus_bridge.ip else n.networks.mgmt.ip;
    in
    "${ip}:${toString topology.hostPorts.node-exporter}"
  ) nixosNodes;

  # public vhosts on the edge Caddy, probed for availability + cert expiry
  publicVhosts = [
    "https://auth.minz1.com"
    "https://grafana.minz1.com"
    "https://jellyfin.minz1.com"
    "https://seerr.minz1.com"
    "https://ntfy.minz1.com"
    "https://admin.minz1.com/media"
    "https://arr.minz1.com/sonarr"
  ];

  blackboxConfig = pkgs.writeText "blackbox.yml" (
    builtins.toJSON {
      modules.http_2xx.prober = "http";
      modules.http_2xx.timeout = "10s";
      modules.http_2xx.http = {
        method = "GET";
        follow_redirects = true;
        preferred_ip_protocol = "ip4";
      };
      # unprivileged ICMP via net.ipv4.ping_group_range; the hardened unit has no CAP_NET_RAW
      modules.icmp = {
        prober = "icmp";
        timeout = "2s";
        icmp.preferred_ip_protocol = "ip4";
      };
    }
  );
in
{
  imports = [
    ./alerting.nix
    ./grafana.nix
  ];

  system.stateVersion = "25.11";

  services.victoriametrics = {
    enable = true;
    listenAddress = ":${toString victoriaPort}";
    # aligned with Loki retention below, so a metric explains a log weeks later
    retentionPeriod = "90d";
    prometheusConfig.scrape_configs = [
      {
        job_name = "node";
        scheme = "https";
        tls_config = mtlsClient;
        static_configs = [ { targets = nodeExporterTargets; } ];
      }
      {
        job_name = "victoriametrics";
        static_configs = [ { targets = [ "127.0.0.1:${toString victoriaPort}" ]; } ];
      }
      {
        job_name = "loki";
        static_configs = [ { targets = [ "127.0.0.1:${toString lokiPort}" ]; } ];
      }
      {
        # no fleet-wide node-cert exporter: internal certs renew every 6h, so acme-renewal-failed fires long before one expires
        job_name = "blackbox";
        metrics_path = "/probe";
        params.module = [ "http_2xx" ];
        static_configs = [ { targets = publicVhosts; } ];
        relabel_configs = [
          {
            source_labels = [ "__address__" ];
            target_label = "__param_target";
          }
          {
            source_labels = [ "__param_target" ];
            target_label = "instance";
          }
          {
            target_label = "__address__";
            replacement = "127.0.0.1:${toString blackboxPort}";
          }
        ];
      }
      {
        job_name = "tunnel";
        scrape_interval = "15s";
        metrics_path = "/probe";
        params.module = [ "icmp" ];
        static_configs = [ { targets = fleet.tunnelEndpoints; } ];
        relabel_configs = [
          {
            source_labels = [ "__address__" ];
            target_label = "__param_target";
          }
          {
            source_labels = [ "__param_target" ];
            target_label = "instance";
          }
          {
            target_label = "__address__";
            replacement = "127.0.0.1:${toString blackboxPort}";
          }
        ];
      }
      {
        # loopback-only; per-domain series dropped below to bound cardinality
        job_name = "adguard";
        static_configs = [ { targets = [ "127.0.0.1:${toString adguardExporterPort}" ]; } ];
        metric_relabel_configs = [
          {
            source_labels = [ "__name__" ];
            regex = "adguard_(top_queried_domains|top_blocked_domains)";
            action = "drop";
          }
        ];
      }
    ];
  };

  services.loki = {
    enable = true;
    # grafana/loki#8468: with deletion_mode disabled every query logs a failed cache-gen RPC
    package = pkgs.grafana-loki.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [ ./loki-cache-gen-deletion-disabled.patch ];
    });
    configuration = {
      auth_enabled = false;
      server = {
        http_listen_address = "127.0.0.1";
        http_listen_port = lokiPort;
        grpc_listen_port = 9096;
      };
      common = {
        instance_addr = "127.0.0.1";
        path_prefix = "/var/lib/loki";
        storage.filesystem = {
          chunks_directory = "/var/lib/loki/chunks";
          rules_directory = "/var/lib/loki/rules";
        };
        replication_factor = 1;
        ring.kvstore.store = "inmemory";
      };
      schema_config.configs = [
        {
          from = "2024-01-01";
          store = "tsdb";
          object_store = "filesystem";
          schema = "v13";
          index = {
            prefix = "index_";
            period = "24h";
          };
        }
      ];
      # 90d minimum — breaches are typically discovered weeks after the fact
      limits_config = {
        retention_period = "90d";
        retention_stream = [
          {
            selector = ''{job="adguard-querylog"}'';
            priority = 1;
            period = "30d";
          }
        ];
        # retention still runs via the compactor; this only closes the delete API
        deletion_mode = "disabled";
      };
      compactor = {
        working_directory = "/var/lib/loki/compactor";
        retention_enabled = true;
        delete_request_store = "filesystem";
      };
      analytics.reporting_enabled = false;
    };
  };

  homelab.internalProxy.servers = {
    grafana = {
      port = grafanaHttpsPort;
      clientAuth = "require";
      allowedClientNodes = [ "minz-vultr-nix-1" ];
      upstream = grafanaPort;
    };
    loki = {
      port = lokiHttpsPort;
      clientAuth = "require";
      handshakeSources = [
        topology.networks.incus_bridge.subnet
        topology.networks.mgmt.subnet
        topology.networks.edge.subnet
      ];
      upstream = lokiPort;
    };
  };

  security.acme.certs."minz-obs-0.internal".reloadServices = [ "grafana.service" ];

  swapDevices = [
    {
      device = "/persist/swapfile";
      size = 2048;
    }
  ];

  networking.firewall.allowedTCPPorts = [
    lokiHttpsPort
    grafanaHttpsPort
  ];

  systemd.services.loki.serviceConfig = mkHardened {
    umask = "0077";
    addressFamilies = [
      "AF_INET"
      "AF_UNIX"
    ];
  };

  systemd.services.victoriametrics.serviceConfig =
    (mkHardened {
      umask = "0077";
      privateUsers = false;
    })
    // {
      SupplementaryGroups = [ "caddy" ];
    };
  systemd.services.victoriametrics.after = [ "acme-minz-obs-0.internal.service" ];
  systemd.services.victoriametrics.wants = [ "acme-minz-obs-0.internal.service" ];

  # not an AdGuard DNS rewrite: would make resolving AdGuard depend on it being up. types.lines appends to common.nix's own entry.
  networking.extraHosts = "192.168.0.1  router.minz1.com\n";

  services.prometheus.exporters.blackbox = {
    enable = true;
    listenAddress = "127.0.0.1";
    configFile = blackboxConfig;
  };
  # umask = null: upstream's own module already sets UMask 0077, conflicts if both set it
  systemd.services.prometheus-blackbox-exporter.serviceConfig = mkHardened { umask = null; };

  sops.secrets."adguard_exporter_env".restartUnits = [
    "adguard-exporter.service"
  ];

  systemd.services.adguard-exporter = {
    description = "Prometheus exporter for AdGuard Home";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = mkHardened { } // {
      DynamicUser = true;
      EnvironmentFile = config.sops.secrets."adguard_exporter_env".path;
      Environment = [ "BIND_ADDR=127.0.0.1:${toString adguardExporterPort}" ];
      ExecStart = lib.getExe pkgs.adguard-exporter;
      Restart = "on-failure";
      RestartSec = "10s";
    };
  };

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/private/victoriametrics";
      mode = "0700";
    }
    {
      directory = "/var/lib/loki";
      user = config.services.loki.user;
      group = config.services.loki.group;
      mode = "0750";
    }
    {
      directory = "/var/lib/grafana";
      user = "grafana";
      group = "grafana";
      mode = "0700";
    }
  ];
}
