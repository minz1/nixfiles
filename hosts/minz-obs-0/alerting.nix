{
  config,
  lib,
  topology,
  fleet,
  ...
}:

let
  criticalInstances =
    map (n: "${fleet.addressOf "minz-obs-0" n}:${toString topology.hostPorts.node-exporter}")
      [
        "minz-vultr-nix-0"
        "minz-pki-0"
      ];
  criticalRe = lib.concatStringsSep "|" criticalInstances;
  # internet names only: home.arpa and reverse/local zones are LAN noise (Ruckus AP lookups)
  nxdomainSelector = ''{job="adguard-querylog"} | json | Rcode="3" | QH=~".+\\..+" | QH!~".+\\.(home\\.arpa|in-addr\\.arpa|ip6\\.arpa|local|lan|invalid|internal)"'';
  nodeTargets =
    lib.concatMap (s: s.targets)
      (lib.findFirst (
        j: j.job_name == "node"
      ) null config.services.victoriametrics.prometheusConfig.scrape_configs).static_configs;

  # alert rule shape: query A -> threshold expression C -> condition = C (Grafana's current UI-exported shape)
  mkRule =
    {
      uid,
      title,
      for ? "5m",
      summary,
      noDataState ? "OK",
      severity ? "warning",
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
      labels.severity = severity;
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
  assertions = [
    {
      assertion = lib.all (i: lib.elem i nodeTargets) criticalInstances;
      message = "alerting.nix: critical instances ${criticalRe} are not all node scrape targets";
    }
  ];

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
                url = "https://${topology.services.services-caddy.host}.internal/";
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
        {
          orgId = 1;
          uid = "adguard-nxdomain-spike";
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
              uid = "disk-root";
              title = "Disk usage / high";
              expr = ''100 - (node_filesystem_avail_bytes{mountpoint="/", fstype!="tmpfs"} / node_filesystem_size_bytes{mountpoint="/", fstype!="tmpfs"} * 100)'';
              evaluatorType = "gt";
              evaluatorParams = [ 85 ];
              for = "10m";
              summary = "{{ $labels.instance }} / usage above 85%";
            })
            (mkThresholdRule {
              uid = "node-scrape-down";
              title = "Host metrics unreachable";
              expr = ''up{job=~"node|tunnel", instance!~"${criticalRe}"}'';
              evaluatorType = "lt";
              evaluatorParams = [ 1 ];
              for = "10m";
              summary = "{{ $labels.job }} scrape of {{ $labels.instance }} failing — host down, exporter down, or its TLS cert invalid";
            })
            (mkThresholdRule {
              uid = "node-scrape-down-critical";
              title = "Hub/PKI metrics unreachable";
              expr = ''up{job="node", instance=~"${criticalRe}"}'';
              evaluatorType = "lt";
              evaluatorParams = [ 1 ];
              for = "10m";
              severity = "critical";
              summary = "{{ $labels.instance }} (WireGuard hub or step-ca) scrape failing — host down, exporter down, or its TLS cert invalid";
            })
            (mkThresholdRule {
              uid = "memory-low";
              title = "Available memory low";
              expr = "node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100";
              evaluatorType = "lt";
              evaluatorParams = [ 5 ];
              for = "15m";
              summary = "{{ $labels.instance }} has under 5% memory available";
            })
            (mkThresholdRule {
              uid = "zfs-pool-unhealthy";
              title = "ZFS pool not online";
              # LXC guests export the host's pool too; max by collapses the duplicates
              expr = ''max by (zpool, state) (node_zfs_zpool_state{state!="online"})'';
              evaluatorType = "gt";
              evaluatorParams = [ 0 ];
              summary = "ZFS pool {{ $labels.zpool }} is {{ $labels.state }}";
            })
            (mkThresholdRule {
              uid = "disk-decypharr-cache";
              title = "Decypharr cache volume nearly full";
              expr = ''100 - (node_filesystem_avail_bytes{mountpoint="/var/cache/decypharr"} / node_filesystem_size_bytes{mountpoint="/var/cache/decypharr"} * 100)'';
              evaluatorType = "gt";
              evaluatorParams = [ 90 ];
              for = "30m";
              summary = "{{ $labels.instance }} decypharr cache volume above 90% — eviction isn't keeping up with diskCacheSize";
            })
            (mkLogCountRule {
              uid = "oom-kill";
              title = "Kernel OOM kill";
              logql = ''sum by (host, memcg, task) (count_over_time({transport="kernel"} |= "oom-kill:" | regexp "task_memcg=(?P<memcg>[^,]+),task=(?P<task>[^,]+)" [10m]))'';
              threshold = 0;
              summary = "{{ $labels.host }}: kernel OOM-killed {{ $labels.task }} in {{ $labels.memcg }}";
            })
            (mkLogCountRule {
              uid = "crash-loop";
              title = "Service crash loop";
              logql = ''sum by (host, svc) (count_over_time({syslog_identifier="systemd"} |= "Scheduled restart job" | regexp "^(?P<svc>[^:]+): Scheduled restart" [30m]))'';
              threshold = 3;
              from = 1800;
              summary = "{{ $labels.svc }} on {{ $labels.host }} restarted more than 3 times in 30m";
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
              # activating: Restart=on-failure parks a failing renewal in auto-restart, never "failed"
              expr = ''node_systemd_unit_state{name=~"acme-.*", state=~"failed|activating"}'';
              evaluatorType = "gt";
              evaluatorParams = [ 0 ];
              for = "30m";
              summary = "{{ $labels.name }} failed on {{ $labels.instance }} — internal certs are 168h, pki-0 may be unreachable";
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
              expr = ''probe_success{job="blackbox"}'';
              evaluatorType = "lt";
              evaluatorParams = [ 1 ];
              summary = "{{ $labels.instance }} failed its blackbox probe";
            })
            (mkThresholdRule {
              uid = "tunnel-packet-loss";
              title = "WireGuard tunnel packet loss";
              expr = ''1 - avg_over_time(probe_success{job="tunnel"}[30m])'';
              evaluatorType = "gt";
              evaluatorParams = [ 0.05 ];
              for = "30m";
              summary = "{{ $labels.instance }} loses over 5% of pings across the WireGuard tunnel; toggle the tunnel (new source port); see main-plan 'attic copy stall on deploys'";
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
              logql = ''sum by (host) (count_over_time({unit="decypharr.service"} |~ "Failed to start mount manager|FUSE handler panic" [10m])) or sum by (host) (count_over_time({unit=~"(jellyfin|sonarr|radarr).service"} |~ "(?i)transport endpoint is not connected" [10m]))'';
              threshold = 0;
              summary = "Decypharr FUSE mount failed to start, panicked, or left consumers on a dead mount";
            })
            (mkLogCountRule {
              uid = "decypharr-prune-aborted";
              title = "Decypharr prune aborted";
              logql = ''sum by (host) (count_over_time({unit="decypharr.service"} |= "prune aborted" [2h]))'';
              threshold = 0;
              summary = "decypharr's prune run aborted (fail-closed); check the reason field and GET /api/prune/status";
            })
            (mkLogCountRule {
              uid = "svc-exec-nonstore";
              title = "Service exec from outside /nix/store";
              # UID="oci"/"podman-runner" excluded: game-0's container and CI job containers have their own rootfs.
              logql = ''
                sum by (host) (
                  count_over_time(
                    {syslog_identifier="audisp-syslog"}
                      |= "type=SYSCALL"
                      |= "key=\"svc-exec\""
                      !~ "exe=\"/nix/store/"
                      !~ "UID=\"(oci|podman-runner)\""
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
              # excluded: pg_dumpall's sh, Forgejo's bash git hooks, CI job containers
              logql = ''
                sum by (host) (
                  count_over_time(
                    {syslog_identifier="audisp-syslog"}
                      |= "type=SYSCALL"
                      |= "key=\"svc-exec\""
                      |~ "comm=\"(sh|bash|dash|ash|zsh|ksh|python[0-9.]*|perl|ruby|php|node|lua[0-9.]*)\""
                      !~ "comm=\"sh\".*UID=\"postgres\""
                      !~ "comm=\"bash\".*UID=\"forgejo\""
                      !~ "UID=\"podman-runner\""
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
              # SSH is WG/bridge-only plus home-nix-0's LAN break-glass; anything outside these prefixes is anomalous.
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
                      |= "type=SYSCALL"
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
            (mkLogCountRule {
              uid = "adguard-querylog-silent";
              title = "AdGuard query log stream silent";
              logql = ''sum(count_over_time({job="adguard-querylog"}[30m]))'';
              threshold = 1;
              evaluatorType = "lt";
              noDataState = "Alerting";
              from = 1800;
              for = "15m";
              summary = "No AdGuard query-log lines in 30m — if router-syslog-silent also fires it is the transport, else check /etc/init.d/adguard-querylog on the router";
            })
            (mkLogCountRule {
              uid = "adguard-nxdomain-client";
              title = "LAN client hammering nonexistent domains";
              logql = "sum by (IP) (count_over_time(${nxdomainSelector} [1h]))";
              threshold = 1000;
              from = 3600;
              for = "10m";
              summary = "{{ $labels.IP }} got over 1000 NXDOMAIN answers in 1h; see its Rcode=3 names in Explore ({job=adguard-querylog})";
            })
            (mkLogCountRule {
              uid = "adguard-nxdomain-names";
              title = "LAN client looking up many nonexistent domains";
              logql = "count by (IP) (sum by (IP, QH) (count_over_time(${nxdomainSelector} [1h])))";
              threshold = 100;
              from = 3600;
              for = "10m";
              summary = "{{ $labels.IP }} looked up over 100 distinct nonexistent names in 1h (DGA-shaped); see its Rcode=3 names in Explore ({job=adguard-querylog})";
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
            (mkLogCountRule {
              uid = "nft-drop-denied";
              title = "Incus ACL denying real traffic";
              logql = ''
                sum by (host) (
                  count_over_time(
                    {transport="kernel"}
                      |~ "eth0-(ingress|egress) "
                      != "PROTO=ICMPv6"
                      !~ "DST=(ff[0-9a-f]{2}:|22[4-9]\\.|23[0-9]\\.|255\\.255\\.255\\.255 )"
                      !~ "RES=0x00 RST URGP="
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
          group_by = [
            "alertname"
            "IP"
          ];
          group_wait = "30s";
          group_interval = "5m";
          repeat_interval = "4h";
          routes = [
            {
              object_matchers = [
                [
                  "severity"
                  "="
                  "critical"
                ]
              ];
              repeat_interval = "1h";
            }
          ];
        }
      ];
    };
  };
}
