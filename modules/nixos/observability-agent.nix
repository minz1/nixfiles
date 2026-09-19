{
  config,
  lib,
  hostEndpoints,
  mkHardened,
  ...
}:

let
  loki = hostEndpoints."minz-obs-0".loki;
  lokiUrl = "https://${loki.ip}:${toString loki.port}/loki/api/v1/push";
  certName = "${config.networking.hostName}.internal";
  certDir = "/var/lib/acme/${certName}";
in
{
  # Host-specific Alloy components go in their own environment.etc."alloy/<name>.alloy":
  # Alloy loads the whole /etc/alloy directory as one module.
  config = {
    environment.etc."node-exporter-web.yml" = {
      text = ''
        tls_server_config:
          cert_file: ${certDir}/fullchain.pem
          key_file: ${certDir}/key.pem
          client_auth_type: RequireAndVerifyClientCert
          client_ca_file: /etc/ssl/internal-ca.crt
      '';
    };

    services.prometheus.exporters.node = {
      enable = true;
      openFirewall = true;
      extraFlags = [
        "--web.config.file=/etc/node-exporter-web.yml"
        # scoped to bound cardinality; restic-backups-*.timer carve-out for staleness alerting
        "--collector.systemd"
        "--collector.systemd.unit-include=(.+\\.service|restic-backups-.+\\.timer)"
      ];
    };

    # upstream's default hardening lacks AF_UNIX, silently breaking the systemd collector's dbus dial
    systemd.services.prometheus-node-exporter.serviceConfig = {
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_NETLINK"
        "AF_UNIX"
      ];
      SupplementaryGroups = [ "caddy" ];
    };
    systemd.services.prometheus-node-exporter.after = [
      "acme-${certName}.service"
    ];
    systemd.services.prometheus-node-exporter.wants = [
      "acme-${certName}.service"
    ];

    services.alloy = {
      enable = true;
      extraFlags = [ "--disable-reporting" ];
    };

    environment.etc."alloy/config.alloy" = {
      text = ''
        loki.source.journal "journal" {
          forward_to    = [loki.write.default.receiver]
          relabel_rules = loki.relabel.journal.rules
          labels = {
            job = "systemd-journal",
          }
        }

        loki.relabel "journal" {
          forward_to = []
          rule {
            source_labels = ["__journal__hostname"]
            target_label  = "host"
          }
          rule {
            source_labels = ["__journal__systemd_unit"]
            target_label  = "unit"
          }
          rule {
            source_labels = ["__journal__priority"]
            target_label  = "level"
          }
          // kernel messages have no _SYSTEMD_UNIT
          rule {
            source_labels = ["__journal__transport"]
            target_label  = "transport"
          }
          rule {
            source_labels = ["__journal_syslog_identifier"]
            target_label  = "syslog_identifier"
          }
        }

        loki.write "default" {
          endpoint {
            url = "${lokiUrl}"
            tls_config {
              ca_file   = "/etc/ssl/internal-ca.crt"
              cert_file = "${certDir}/fullchain.pem"
              key_file  = "${certDir}/key.pem"
            }
          }
        }
      '';
    };

    # privateUsers=false: PrivateUsers conflicts with SupplementaryGroups on DynamicUser
    systemd.services.alloy.serviceConfig = (
      # bpf: Alloy probes for eBPF at startup; SIGSYS without it even with empty CapabilityBoundingSet
      (mkHardened {
        privateUsers = false;
        extraSystemCallFilter = [
          "@chown"
          "bpf"
        ];
      })
      // {
        SupplementaryGroups = [
          "systemd-journal"
          "caddy"
        ];
      }
    );

    # mkIf guards the whole cert key to avoid spurious ACME entries on WG-only hosts;
    # node-exporter needs a reload too, or a renewal never reaches its already-running process
    security.acme.certs = {
      ${certName}.reloadServices = [
        "alloy.service"
        "prometheus-node-exporter.service"
      ];
    };

    systemd.services.alloy.after = [
      "acme-${certName}.service"
    ];
    systemd.services.alloy.wants = [
      "acme-${certName}.service"
    ];

    # DynamicUser: persist /var/lib/private/alloy, not the /var/lib/alloy symlink
    environment.persistence."/persist".directories = lib.mkIf (config.fileSystems ? "/persist") [
      {
        directory = "/var/lib/private/alloy";
        mode = "0700";
      }
    ];
  };
}
