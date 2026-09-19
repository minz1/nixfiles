{ ... }:

let
  # alert rule shape: query A -> threshold expression C -> condition = C (Grafana's current UI-exported shape)
  mkRule =
    {
      uid,
      title,
      for ? "5m",
      summary,
      noDataState ? "OK",
      query,
      evaluatorType,
      evaluatorParams,
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
        (query // { refId = "A"; })
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

  mkThresholdRule =
    { expr, ... }@args:
    mkRule (
      removeAttrs args [ "expr" ]
      // {
        query = {
          datasourceUid = "victoriametrics";
          relativeTimeRange = {
            from = 600;
            to = 0;
          };
          model = {
            inherit expr;
            instant = true;
            refId = "A";
          };
        };
      }
    );

  # NB: `logql` must wrap its count_over_time(...) in `sum by (...) (...)` — Loki shards high-volume streams internally (__stream_shard__), so an unaggregated query returns one series per shard per host, and per-shard churn defeats repeat_interval.
  mkLogCountRule =
    {
      logql,
      threshold,
      evaluatorType ? "gt",
      from ? 600,
      ...
    }@args:
    mkRule (
      removeAttrs args [
        "logql"
        "threshold"
        "from"
      ]
      // {
        inherit evaluatorType;
        evaluatorParams = [ threshold ];
        query = {
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
        };
      }
    );
in
{
  services.grafana.provision = {
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

    # openwrt-firewall-drops omitted: OpenWrt doesn't log firewall drops by default, no data source yet
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
            (mkThresholdRule {
              uid = "adguard-nxdomain-spike";
              title = "AdGuard NXDOMAIN rate spike";
              expr = ''sum(rate(adguard_queries_details{reason="NotFilteredNotFound"}[5m]))'';
              evaluatorType = "gt";
              evaluatorParams = [ 25 ];
              for = "15m";
              summary = "AdGuard NXDOMAIN rate above 25 q/s (6d observed max: ~19 q/s)";
            })
            (mkLogCountRule {
              uid = "nft-drop-denied";
              title = "Incus ACL denying real traffic";
              logql = ''
                sum by (host) (
                  count_over_time(
                    {transport="kernel"}
                      |~ "eth0-(ingress|egress) "
                      != "PROTO=ICMPv6"
                      != "DST=224.0.0.251"
                    [10m]
                  )
                )
              '';
              threshold = 0;
              for = "10m";
              summary = "{{ $labels.host }} logged a non-multicast Incus ACL drop — check for a legitimate flow being denied";
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
}
