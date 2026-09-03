{
  config,
  lib,
  hostEndpoints,
  ...
}:

let
  mkHardened = import ../lib/hardening.nix { inherit lib; };
  topology = import ../../common/topology.nix;
  lokiEndpoint = (hostEndpoints."minz-obs-0" or { })."loki" or null;
  lokiUrl =
    if lokiEndpoint != null then
      "https://${lokiEndpoint.ip}:${toString lokiEndpoint.port}/loki/api/v1/push"
    else
      null;
  enableAlloy = lokiUrl != null;

  # topology-driven: avoids self-inspection cycles in NixOS config
  thisNode = topology.nodes.${config.networking.hostName} or null;
  hasInternalNetwork =
    thisNode != null && ((thisNode.networks ? incus_bridge) || (thisNode.networks ? mgmt));
  certName = "${config.networking.hostName}.internal";
  enableClientCert = enableAlloy && hasInternalNetwork;
  certDir = "/var/lib/acme/${certName}";
in
{
  options.homelab.observability.extraAlloyConfig = lib.mkOption {
    type = lib.types.lines;
    default = "";
    description = ''
      Extra Alloy River config appended to the fleet-wide config.alloy, for
      host-specific River components (e.g. home-nix-0's loki.source.syslog
      listener for the OpenWRT router). Mirrors the extension-point style of
      modules/nixos/endpoints.nix.
    '';
  };

  config = {
    environment.etc."node-exporter-web.yml" = lib.mkIf enableClientCert {
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
      extraFlags = lib.optional enableClientCert "--web.config.file=/etc/node-exporter-web.yml" ++ [
        # scoped to .service units to bound cardinality; prereq for "service down"/"cert renewal failing" alerts (docs/main-plan.md S4)
        "--collector.systemd"
        "--collector.systemd.unit-include=.+\\.service"
      ];
    };

    # upstream's default hardening lacks AF_UNIX, silently breaking the systemd collector's dbus dial (docs/main-plan.md S4)
    systemd.services.prometheus-node-exporter.serviceConfig = {
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_NETLINK"
        "AF_UNIX"
      ];
    }
    // lib.optionalAttrs enableClientCert {
      SupplementaryGroups = [ "caddy" ];
    };
    systemd.services.prometheus-node-exporter.after = lib.mkIf enableClientCert [
      "acme-${certName}.service"
    ];
    systemd.services.prometheus-node-exporter.wants = lib.mkIf enableClientCert [
      "acme-${certName}.service"
    ];

    services.alloy = {
      enable = enableAlloy;
      extraFlags = [ "--disable-reporting" ];
    };

    environment.etc."alloy/config.alloy" = lib.mkIf enableAlloy {
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
          // kernel messages have no _SYSTEMD_UNIT; see docs/main-plan.md S4
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
            ${lib.optionalString enableClientCert ''
              tls_config {
                ca_file   = "/etc/ssl/internal-ca.crt"
                cert_file = "${certDir}/fullchain.pem"
                key_file  = "${certDir}/key.pem"
              }
            ''}
          }
        }

        ${config.homelab.observability.extraAlloyConfig}
      '';
    };

    # privateUsers=false: PrivateUsers conflicts with SupplementaryGroups on DynamicUser
    systemd.services.alloy.serviceConfig = lib.mkIf enableAlloy (
      # bpf: Alloy probes for eBPF at startup; SIGSYS without it even with empty CapabilityBoundingSet
      (mkHardened {
        privateUsers = false;
        extraSystemCallFilter = [
          "@chown"
          "bpf"
        ];
      })
      // {
        SupplementaryGroups = [ "systemd-journal" ] ++ lib.optional enableClientCert "caddy";
      }
    );

    # mkIf guards the whole cert key to avoid spurious ACME entries on WG-only hosts
    security.acme.certs = lib.mkIf enableClientCert {
      ${certName}.reloadServices = [ "alloy.service" ];
    };

    systemd.services.alloy.after = lib.mkIf enableClientCert [
      "acme-${certName}.service"
    ];
    systemd.services.alloy.wants = lib.mkIf enableClientCert [
      "acme-${certName}.service"
    ];

    # DynamicUser: persist /var/lib/private/alloy, not the /var/lib/alloy symlink
    environment.persistence."/persist".directories =
      lib.mkIf (enableAlloy && config.fileSystems ? "/persist")
        [
          {
            directory = "/var/lib/private/alloy";
            mode = "0700";
          }
        ];
  };
}
