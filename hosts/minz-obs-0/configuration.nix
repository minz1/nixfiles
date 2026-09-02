{
  hostName,
  config,
  lib,
  pkgs,
  hostEndpoints,
  ...
}:

let
  mkHardened = import ../../modules/lib/hardening.nix { inherit lib; };
  topology = import ../../common/topology.nix;
  node = topology.nodes."${hostName}";
  obsIp = node.networks.incus_bridge.ip;
  acmeHttpPort = 80;

  victoriaPort = 9090;
  lokiPort = 3100;
  lokiHttpsPort = 3101;
  grafanaPort = 3000;
  blackboxPort = 9115;
  adguardExporterPort = 9618;
  certDir = "/var/lib/acme/minz-obs-0.internal";

  authentikHttpsPort = hostEndpoints.minz-authentik-0.authentik.port;

  nixosNodes = lib.filterAttrs (_: n: n.os == "nixos") topology.nodes;
  nodeExporterTargets = lib.mapAttrsToList (
    _: n:
    let
      ip = if n.networks ? incus_bridge then n.networks.incus_bridge.ip else n.networks.mgmt.ip;
    in
    "${ip}:9100"
  ) nixosNodes;

  # public vhosts on the edge Caddy, probed for availability + cert expiry (docs/main-plan.md S4)
  publicVhosts = [
    "https://auth.minz1.com"
    "https://grafana.minz1.com"
    "https://jellyfin.minz1.com"
    "https://seerr.minz1.com"
    "https://memos.minz1.com"
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

  # alert rule helpers: query -> threshold expression -> condition = expr's refId (Grafana's current UI-exported shape)
  mkThresholdRule =
    {
      uid,
      title,
      expr,
      evaluatorType,
      evaluatorParams,
      for ? "5m",
      summary,
      instant ? true,
    }:
    {
      inherit uid title;
      condition = "C";
      for = for;
      noDataState = "OK";
      execErrState = "Error";
      annotations.summary = summary;
      labels.severity = "warning";
      data = [
        {
          refId = "A";
          datasourceUid = "victoriametrics";
          relativeTimeRange = {
            from = 600;
            to = 0;
          };
          model = {
            inherit expr instant;
            refId = "A";
          };
        }
        {
          refId = "C";
          datasourceUid = "__expr__";
          model = {
            type = "threshold";
            expression = "A";
            conditions = [
              {
                evaluator = {
                  type = evaluatorType;
                  params = evaluatorParams;
                };
              }
            ];
            refId = "C";
          };
        }
      ];
    };

  # NB: `logql` must wrap its count_over_time(...) in `sum by (...) (...)`. Loki
  # shards high-volume streams internally (__stream_shard__), so an unaggregated
  # count_over_time returns one series per shard per host — Grafana then creates
  # a separate alert instance per shard, and per-shard churn defeats repeat_interval.
  mkLogCountRule =
    {
      uid,
      title,
      logql,
      threshold,
      for ? "5m",
      summary,
    }:
    {
      inherit uid title;
      condition = "C";
      for = for;
      noDataState = "OK";
      execErrState = "Error";
      annotations.summary = summary;
      labels.severity = "warning";
      data = [
        {
          refId = "A";
          datasourceUid = "loki";
          relativeTimeRange = {
            from = 600;
            to = 0;
          };
          model = {
            expr = logql;
            queryType = "instant";
            refId = "A";
          };
        }
        {
          refId = "C";
          datasourceUid = "__expr__";
          model = {
            type = "threshold";
            expression = "A";
            conditions = [
              {
                evaluator = {
                  type = "gt";
                  params = [ threshold ];
                };
              }
            ];
            refId = "C";
          };
        }
      ];
    };
in
{
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
        # no fleet-wide node-cert exporter: internal 24h certs make a days-remaining threshold meaningless (docs/main-plan.md S4)
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
            tags = [ "loki" ];
          }
        ];
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

  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_addr = "0.0.0.0";
        http_port = grafanaPort;
        protocol = "https";
        cert_file = "/var/lib/acme/minz-obs-0.internal/cert.pem";
        cert_key = "/var/lib/acme/minz-obs-0.internal/key.pem";
        domain = "grafana.minz1.com";
        root_url = "https://grafana.minz1.com/";
      };
      security = {
        admin_user = "admin";
        # $__file{} is expanded by Grafana's file provider at runtime.
        admin_password = "$__file{${config.sops.secrets.grafana_admin_password.path}}";
        secret_key = "$__file{${config.sops.secrets.grafana_secret_key.path}}";
        cookie_secure = true;
      };
      analytics = {
        reporting_enabled = false;
        check_for_updates = false;
      };
      live = {
        allowed_origins = "https://grafana.minz1.com";
      };
      "auth.generic_oauth" = {
        enabled = true;
        name = "Authentik";
        icon = "signin";
        client_id = "grafana";
        client_secret = "$__file{${config.sops.secrets.grafana_oauth_client_secret.path}}";
        scopes = "openid email profile";
        auth_url = "https://auth.minz1.com/application/o/authorize/";
        token_url = "https://minz-authentik-0.internal:${toString authentikHttpsPort}/application/o/token/";
        api_url = "https://minz-authentik-0.internal:${toString authentikHttpsPort}/application/o/userinfo/";
        role_attribute_path = "contains(groups[*], 'grafana-admins') && 'Admin' || 'Viewer'";
        allow_sign_up = true;
      };
      "auth" = {
        disable_login_form = true;
      };
      # Resend, same provider/creds pattern as authentik-0 and Seerr.
      smtp = {
        enabled = true;
        host = "smtp.resend.com:587";
        user = "resend";
        # $__file{} is expanded by Grafana's file provider at runtime.
        password = "$__file{${config.sops.secrets.grafana_smtp_password.path}}";
        from_address = "noreply@minz1.com";
      };
    };
    provision = {
      enable = true;
      # uid pinned for alert rules; deleteDatasources avoids the update-path crash (docs/main-plan.md S4)
      datasources.settings = {
        deleteDatasources = [
          {
            name = "VictoriaMetrics";
            orgId = 1;
          }
          {
            name = "Loki";
            orgId = 1;
          }
        ];
        datasources = [
          {
            name = "VictoriaMetrics";
            uid = "victoriametrics";
            type = "prometheus";
            url = "http://127.0.0.1:${toString victoriaPort}";
            isDefault = true;
          }
          {
            name = "Loki";
            uid = "loki";
            type = "loki";
            url = "http://127.0.0.1:${toString lokiPort}";
          }
        ];
      };
      # alerting provisioning only interpolates $VAR from the process env, not $__file{} (docs/main-plan.md S4)
      alerting.contactPoints.settings = {
        apiVersion = 1;
        contactPoints = [
          {
            orgId = 1;
            name = "homelab-alerts";
            receivers = [
              {
                uid = "homelab-email";
                type = "email";
                settings.addresses = "emerytang@gmail.com";
              }
              # TODO: SMS receiver via carrier email-to-SMS gateway, needs a phone number/carrier filled in by hand
              {
                uid = "homelab-ntfy";
                type = "webhook";
                settings = {
                  url = "https://minz-services-0.internal/homelab-alerts";
                  httpMethod = "POST";
                  # ngalert's webhook schema, not the legacy basicAuthUsername/basicAuthPassword names (docs/main-plan.md S4)
                  username = "grafana";
                  password = "$NTFY_PASSWORD";
                };
              }
            ];
          }
        ];
      };
      # nft-drop/AdGuard/OpenWRT rules deliberately omitted — no data yet; see docs/main-plan.md S4
      alerting.rules.settings = {
        apiVersion = 1;
        groups = [
          {
            orgId = 1;
            name = "homelab";
            folder = "Homelab";
            interval = "1m";
            rules = [
              (mkThresholdRule {
                uid = "disk-persist";
                title = "Disk usage /persist high";
                expr = ''100 - (node_filesystem_avail_bytes{mountpoint="/persist"} / node_filesystem_size_bytes{mountpoint="/persist"} * 100)'';
                evaluatorType = "gt";
                evaluatorParams = [ 85 ];
                summary = "{{ $labels.instance }} /persist usage above 85%";
              })
              (mkThresholdRule {
                uid = "disk-nix";
                title = "Disk usage /nix high";
                expr = ''100 - (node_filesystem_avail_bytes{mountpoint="/nix"} / node_filesystem_size_bytes{mountpoint="/nix"} * 100)'';
                evaluatorType = "gt";
                evaluatorParams = [ 85 ];
                summary = "{{ $labels.instance }} /nix usage above 85%";
              })
              (mkThresholdRule {
                uid = "service-down";
                title = "systemd service failed";
                expr = ''node_systemd_unit_state{state="failed"}'';
                evaluatorType = "gt";
                evaluatorParams = [ 0 ];
                summary = "{{ $labels.name }} failed on {{ $labels.instance }}";
              })
              (mkThresholdRule {
                uid = "acme-renewal-failed";
                title = "ACME cert renewal failing";
                expr = ''node_systemd_unit_state{name=~"acme-.*", state="failed"}'';
                evaluatorType = "gt";
                evaluatorParams = [ 0 ];
                summary = "{{ $labels.name }} failed on {{ $labels.instance }} — internal certs are 24h, this needs attention promptly";
              })
              (mkThresholdRule {
                uid = "public-cert-expiry";
                title = "Public certificate expiring soon";
                expr = "probe_ssl_earliest_cert_expiry - time()";
                evaluatorType = "lt";
                evaluatorParams = [ (14 * 24 * 60 * 60) ]; # 14 days, seconds
                for = "1h";
                summary = "{{ $labels.instance }} certificate expires in under 14 days";
              })
              (mkThresholdRule {
                uid = "public-endpoint-down";
                title = "Public endpoint down";
                expr = "probe_success";
                evaluatorType = "lt";
                evaluatorParams = [ 1 ];
                summary = "{{ $labels.instance }} failed its blackbox probe";
              })
              (mkThresholdRule {
                uid = "loki-error-rate";
                title = "Loki error rate spike";
                expr = ''rate(loki_request_duration_seconds_count{status_code=~"5.."}[5m])'';
                evaluatorType = "gt";
                evaluatorParams = [ 0.1 ];
                summary = "Loki 5xx rate elevated on obs-0";
              })
              (mkLogCountRule {
                uid = "decypharr-fuse-failure";
                title = "Decypharr FUSE mount failure";
                logql = ''sum by (host) (count_over_time({unit="decypharr.service"} |~ "(?i)fuse.*(fail|error|unmount)" [10m]))'';
                threshold = 0;
                summary = "Decypharr FUSE mount error logged on media-0";
              })
              (mkLogCountRule {
                uid = "auditd-svc-execve";
                title = "auditd: execve by non-interactive service user";
                # Baseline verified benign against 24h of live Loki data across the fleet
                # (2026-09-02): ACME's renewal post-hook (chown/chmod on the cert dir, plus
                # the lego/minica/coreutils calls it and the systemd-unit-named script
                # ("acme-<truncated>") shell out to) and rootless-podman's per-boot user
                # systemd instance (comm truncated to 15 chars by the kernel, e.g.
                # "systemd-tmpfile", "9"; UID is "oci" on game-0, "podman-runner" on
                # vultr-nix-0 — same activity, different service account name per host).
                logql = ''
                  sum by (host) (
                    count_over_time(
                      {syslog_identifier="audisp-syslog"}
                        |= "key=\"svc-exec\""
                        !~ "comm=\"(chmod|chown|cmp|cp|mv|touch|find|flock|seq|cat|ln|lego|minica|acme-[^\"]*)\".*UID=\"acme\""
                        !~ "comm=\"(systemd-xdg-aut|podman-user-gen|30-systemd-envi|systemd-tmpfile|systemd-executor|switch-to-confi|systemd|9)\".*UID=\"(oci|podman-runner)\""
                      [10m]
                    )
                  )
                '';
                threshold = 0;
                summary = "Unexpected execve by a service-user (uid<1000) — {{ $labels.host }}";
              })
            ];
          }
        ];
      };

      alerting.policies.settings = {
        apiVersion = 1;
        policies = [
          {
            orgId = 1;
            receiver = "homelab-alerts";
            group_by = [ "alertname" ];
            group_wait = "30s";
            group_interval = "5m";
            repeat_interval = "4h";
          }
        ];
      };
    };
  };

  sops.secrets.grafana_smtp_password = {
    mode = "0400";
    owner = "grafana";
  };

  # plaintext, sent over HTTP Basic Auth; distinct from ntfy_grafana_password_hash on services-0, same source password
  sops.secrets.ntfy_grafana_password = {
    mode = "0400";
    owner = "grafana";
  };

  sops.templates."grafana-alerting-env" = {
    content = "NTFY_PASSWORD=${config.sops.placeholder.ntfy_grafana_password}";
    owner = "grafana";
    mode = "0400";
  };

  sops.secrets.grafana_admin_password = {
    mode = "0400";
    owner = "grafana";
  };

  sops.secrets.grafana_secret_key = {
    mode = "0400";
    owner = "grafana";
  };

  sops.secrets.grafana_oauth_client_secret = {
    mode = "0400";
    owner = "grafana";
  };

  swapDevices = [
    {
      device = "/persist/swapfile";
      size = 2048;
    }
  ];

  security.acme.certs."minz-obs-0.internal".reloadServices = [ "grafana.service" ];

  users.users.grafana.extraGroups = [ "caddy" ];

  networking.firewall.allowedTCPPorts = [
    lokiHttpsPort
    grafanaPort
    acmeHttpPort
  ];

  systemd.services.loki.serviceConfig = mkHardened {
    umask = "0077";
    addressFamilies = [
      "AF_INET"
      "AF_UNIX"
    ];
  };

  systemd.services.victoriametrics.serviceConfig = (mkHardened {
    umask = "0077";
    privateUsers = false;
  }) // {
    SupplementaryGroups = [ "caddy" ];
  };
  systemd.services.victoriametrics.after = [ "acme-minz-obs-0.internal.service" ];
  systemd.services.victoriametrics.wants = [ "acme-minz-obs-0.internal.service" ];

  systemd.services.grafana.serviceConfig = mkHardened { } // {
    EnvironmentFile = config.sops.templates."grafana-alerting-env".path;
  };
  # environmentFile content changes don't restart the service on their own (docs/main-plan.md S4)
  systemd.services.grafana.restartTriggers = [
    config.sops.templates."grafana-alerting-env".content
  ];

  # not an AdGuard DNS rewrite: would make resolving AdGuard depend on it being up. types.lines appends to common.nix's own entry.
  networking.extraHosts = "192.168.0.1  router.minz1.com\n";

  services.prometheus.exporters.blackbox = {
    enable = true;
    listenAddress = "127.0.0.1";
    configFile = blackboxConfig;
  };
  # umask = null: upstream's own module already sets UMask 0077, conflicts if both set it
  systemd.services.prometheus-blackbox-exporter.serviceConfig = mkHardened { umask = null; };

  # TEMPORARILY DISABLED 2026-09-01: blocks fleet-wide deploys until adguard_exporter_env exists; re-enable steps in docs/ops.md
  /*
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
  */

  homelab.endpoints = {
    loki = {
      ip = obsIp;
      port = lokiHttpsPort;
      tls = true;
    };
    grafana = {
      ip = obsIp;
      port = grafanaPort;
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
