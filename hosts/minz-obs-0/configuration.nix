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
      inherit uid title for;
      condition = "C";
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

  # NB: `logql` must wrap its count_over_time(...) in `sum by (...) (...)` — Loki shards high-volume streams internally (__stream_shard__), so an unaggregated query returns one series per shard per host, and per-shard churn defeats repeat_interval.
  mkLogCountRule =
    {
      uid,
      title,
      logql,
      threshold,
      for ? "5m",
      summary,
      evaluatorType ? "gt",
      noDataState ? "OK",
      from ? 600,
    }:
    {
      inherit
        uid
        title
        for
        noDataState
        ;
      condition = "C";
      execErrState = "Error";
      annotations.summary = summary;
      labels.severity = "warning";
      data = [
        {
          refId = "A";
          datasourceUid = "loki";
          relativeTimeRange = {
            inherit from;
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
                  type = evaluatorType;
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
      # uid pinned for alert rules; deleteDatasources avoids the update-path crash
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
      # alerting provisioning only interpolates $VAR from the process env, not $__file{}
      alerting.contactPoints.settings = {
        apiVersion = 1;
        # file provisioning never auto-deletes a receiver removed from `receivers` below — same as alerting.rules.settings.deleteRules
        deleteContactPoints = [
          {
            orgId = 1;
            uid = "homelab-email";
          }
        ];
        contactPoints = [
          {
            orgId = 1;
            name = "homelab-alerts";
            receivers = [
              {
                uid = "homelab-ntfy";
                type = "webhook";
                settings = {
                  # root URL, not the topic path: ntfy only parses structured JSON (title/priority/tags/click) at the root, keyed by the "topic" field below
                  url = "https://minz-services-0.internal/";
                  httpMethod = "POST";
                  # ngalert's webhook schema, not the legacy basicAuthUsername/basicAuthPassword names
                  username = "grafana";
                  password = "$NTFY_PASSWORD";
                  # settings.payload.template (not payloadTemplate); no `$name` vars (os.Expand blanks unknown $words); tmpl.Exec/define is broken in this Grafana version, and ntfy needs "tags" as a JSON array — all confirmed live against the receiver test API
                  payload.template = ''
                    {{ coll.Dict
                      "topic" "homelab-alerts"
                      "title" (print .CommonLabels.alertname " — " .Status)
                      "message" (print (len .Alerts) " alert(s) — " .CommonAnnotations.summary)
                      "priority" (or (and (eq .Status "firing") 4) 3)
                      "tags" (coll.Slice (or (and (eq .Status "firing") "warning") "white_check_mark") (or .CommonLabels.host .CommonLabels.instance "homelab"))
                      "markdown" true
                      "click" (or (and (gt (len .Alerts) 0) (index .Alerts 0).GeneratorURL) "https://grafana.minz1.com/alerting/list")
                      | data.ToJSON }}
                  '';
                };
              }
            ];
          }
        ];
      };
      # nft-drop/AdGuard/OpenWRT rules deliberately omitted — no data yet
      alerting.rules.settings = {
        apiVersion = 1;
        # file provisioning never auto-deletes orphaned rules removed from `groups` below — needs an explicit entry here or it keeps evaluating forever
        deleteRules = [
          {
            orgId = 1;
            uid = "auditd-svc-execve";
          }
        ];
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
                for = "30m"; # 5m default flapped on boundary crossings (seen on game-0's /persist)
                summary = "{{ $labels.instance }} /persist usage above 85%";
              })
              (mkThresholdRule {
                uid = "disk-nix";
                title = "Disk usage /nix high";
                expr = ''100 - (node_filesystem_avail_bytes{mountpoint="/nix"} / node_filesystem_size_bytes{mountpoint="/nix"} * 100)'';
                evaluatorType = "gt";
                evaluatorParams = [ 85 ];
                for = "30m";
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
                uid = "svc-exec-nonstore";
                title = "Service exec from outside /nix/store";
                # UID="oci" excluded: game-0's container has its own rootfs, not /nix/store.
                logql = ''
                  sum by (host) (
                    count_over_time(
                      {syslog_identifier="audisp-syslog"}
                        |= "key=\"svc-exec\""
                        !~ "exe=\"/nix/store/"
                        !~ "UID=\"oci\""
                        !~ "exe=\"/var/lib/grafana/plugins/"
                      [10m]
                    )
                  )
                '';
                threshold = 0;
                summary = "{{ $labels.host }}: service user exec'd a binary outside /nix/store";
              })
              (mkLogCountRule {
                uid = "svc-exec-shell";
                title = "Shell/interpreter spawned by service user";
                # comm="sh" + UID="postgres" excluded: pg_dumpall spawns its own shell.
                logql = ''
                  sum by (host) (
                    count_over_time(
                      {syslog_identifier="audisp-syslog"}
                        |= "key=\"svc-exec\""
                        |~ "comm=\"(sh|bash|dash|ash|zsh|ksh|python[0-9.]*|perl|ruby|php|node|lua[0-9.]*)\""
                        !~ "comm=\"sh\".*UID=\"postgres\""
                      [10m]
                    )
                  )
                '';
                threshold = 0;
                summary = "{{ $labels.host }}: shell or interpreter exec'd by a service user — possible RCE follow-on";
              })
              (mkLogCountRule {
                uid = "ssh-unexpected-source";
                title = "SSH login from unexpected source";
                # SSH is WireGuard-only on this fleet; anything outside these prefixes is anomalous.
                logql = ''
                  sum by (host) (
                    count_over_time(
                      {unit="sshd.service"}
                        |= "Accepted"
                        !~ " from (10\\.8\\.0\\.|10\\.10\\.0\\.|192\\.168\\.)"
                      [10m]
                    )
                  )
                '';
                threshold = 0;
                summary = "{{ $labels.host }}: accepted SSH login from outside WireGuard/bridge/LAN";
              })
              (mkLogCountRule {
                uid = "ssh-password-auth";
                title = "SSH password authentication used";
                # Password auth is disabled fleet-wide; a successful one should be impossible.
                logql = ''
                  sum by (host) (
                    count_over_time(
                      {unit="sshd.service"} |= "Accepted password"
                      [10m]
                    )
                  )
                '';
                threshold = 0;
                summary = "{{ $labels.host }}: SSH password authentication succeeded";
              })
              (mkLogCountRule {
                uid = "identity-file-write";
                title = "Write to identity/sudoers/sshd config files";
                # comm="perl" excluded: NixOS's update-users-groups.pl rewrites these every deploy.
                logql = ''
                  sum by (host) (
                    count_over_time(
                      {syslog_identifier="audisp-syslog"}
                        |~ "key=\"(identity|sshd|sudoers)\""
                        !~ "comm=\"perl\""
                      [10m]
                    )
                  )
                '';
                threshold = 0;
                summary = "{{ $labels.host }}: write to /etc/passwd, shadow, group, sudoers, or sshd_config outside a deploy";
              })
              (mkThresholdRule {
                uid = "adguard-exporter-down";
                title = "AdGuard exporter down";
                expr = ''up{job="adguard"}'';
                evaluatorType = "lt";
                evaluatorParams = [ 1 ];
                for = "10m";
                summary = "adguard-exporter on obs-0 is not being scraped";
              })
              (mkThresholdRule {
                uid = "adguard-unreachable";
                title = "AdGuard unreachable from its exporter";
                expr = "adguard_running";
                evaluatorType = "lt";
                evaluatorParams = [ 1 ];
                for = "10m";
                summary = "adguard-exporter is up but can't reach AdGuard Home on the router";
              })
              (mkLogCountRule {
                uid = "router-syslog-silent";
                title = "Router syslog stream silent";
                logql = ''sum(count_over_time({job="openwrt-syslog"}[30m]))'';
                threshold = 1;
                evaluatorType = "lt";
                noDataState = "Alerting";
                from = 1800;
                for = "15m";
                summary = "No router syslog lines received in 30m — check stunnel/Alloy syslog listener on home-nix-0";
              })
              (mkThresholdRule {
                uid = "restic-backup-stale";
                title = "restic backup hasn't run recently";
                # "> 0" guard: the metric is 0 for a never-fired timer, else time()-0 reads as ~56y stale.
                expr = ''
                  (time() - node_systemd_timer_last_trigger_seconds{name=~"restic-backups-.+\\.timer"})
                    and node_systemd_timer_last_trigger_seconds{name=~"restic-backups-.+\\.timer"} > 0
                '';
                evaluatorType = "gt";
                evaluatorParams = [ 172800 ]; # 48h
                for = "1h";
                summary = "{{ $labels.name }} on {{ $labels.instance }} hasn't triggered in over 48h";
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

  systemd.services.grafana.serviceConfig = mkHardened { } // {
    EnvironmentFile = config.sops.templates."grafana-alerting-env".path;
  };
  # environmentFile content changes don't restart the service on their own
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
