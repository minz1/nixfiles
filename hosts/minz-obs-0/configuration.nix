{
  hostName,
  config,
  lib,
  pkgs,
  topology,
  node,
  mkHardened,
  ...
}:

let
  obsIp = node.networks.incus_bridge.ip;
  acmeHttpPort = 80;

  victoriaPort = 9090;
  lokiPort = 3100;
  lokiHttpsPort = 3101;
  grafanaPort = 3000;
  grafanaHttpsPort = 3443;
  blackboxPort = 9115;
  adguardExporterPort = 9618;
  certDir = "/var/lib/acme/minz-obs-0.internal";

  nixosNodes = lib.filterAttrs (_: n: n.os == "nixos") topology.nodes;
  nodeExporterTargets = lib.mapAttrsToList (
    _: n:
    let
      ip = if n.networks ? incus_bridge then n.networks.incus_bridge.ip else n.networks.mgmt.ip;
    in
    "${ip}:9100"
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
    }
  );
in
{
  imports = [
    ./alerting.nix
    ./grafana.nix
  ];

  networking.hostName = hostName;
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
        tls_config = {
          ca_file = "/etc/ssl/internal-ca.crt";
          cert_file = "${certDir}/fullchain.pem";
          key_file = "${certDir}/key.pem";
        };
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
        # no fleet-wide node-cert exporter: internal 24h certs make a days-remaining threshold meaningless
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
      limits_config.retention_period = "90d";
      compactor = {
        working_directory = "/var/lib/loki/compactor";
        retention_enabled = true;
        delete_request_store = "filesystem";
      };
      analytics.reporting_enabled = false;
    };
  };

  services.caddy = {
    enable = true;
    settings = {
      apps = {
        tls.certificates.load_files = [
          {
            certificate = "/var/lib/acme/minz-obs-0.internal/cert.pem";
            key = "/var/lib/acme/minz-obs-0.internal/key.pem";
            tags = [
              "loki"
              "grafana"
            ];
          }
        ];
        http.servers.grafana = {
          listen = [ ":${toString grafanaHttpsPort}" ];
          automatic_https.disable = true;
          strict_sni_host = false;
          tls_connection_policies = [
            {
              certificate_selection.any_tag = [ "grafana" ];
              client_authentication = {
                trusted_ca_certs_pem_files = [ "/etc/ssl/internal-ca.crt" ];
                mode = "require_and_verify";
              };
            }
          ];
          routes = [
            {
              match = [
                {
                  not = [
                    { expression = ''{http.request.tls.client.subject} == "CN=minz-vultr-nix-1.internal"''; }
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
                  upstreams = [ { dial = "127.0.0.1:${toString grafanaPort}"; } ];
                  headers.request.set."Host" = [ "{http.request.host}" ];
                }
              ];
            }
          ];
        };
        http.servers.loki = {
          listen = [ ":${toString lokiHttpsPort}" ];
          automatic_https.disable = true;
          # strict_sni_host=false: Loki accessed via IP with no SNI; mTLS provides auth
          strict_sni_host = false;
          tls_connection_policies = [
            {
              match.remote_ip.ranges = [
                topology.networks.incus_bridge.subnet
                topology.networks.mgmt.subnet
              ];
              certificate_selection.any_tag = [ "loki" ];
              client_authentication = {
                trusted_ca_certs_pem_files = [ "/etc/ssl/internal-ca.crt" ];
                mode = "require_and_verify";
              };
            }
            { certificate_selection.any_tag = [ "loki" ]; }
          ];
          routes = [
            {
              handle = [
                {
                  handler = "reverse_proxy";
                  upstreams = [ { dial = "localhost:${toString lokiPort}"; } ];
                  headers.request.set."Host" = [ "{http.request.host}" ];
                }
              ];
            }
          ];
        };
      };
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
    acmeHttpPort
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

  sops.secrets."adguard_exporter_env" = { };

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

  homelab.endpoints = {
    loki = {
      ip = obsIp;
      port = lokiHttpsPort;
      tls = true;
    };
    grafana = {
      ip = obsIp;
      port = grafanaHttpsPort;
      tls = true;
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
    {
      directory = "/var/lib/caddy";
      user = "caddy";
      group = "caddy";
      mode = "0700";
    }
  ];
}
