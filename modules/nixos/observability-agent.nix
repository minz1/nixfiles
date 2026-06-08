{ config, lib, ... }:

let
  topology = import ../../common/topology.nix;
  obsNode = topology.nodes."minz-obs-0" or null;
  lokiIp = if obsNode != null then obsNode.networks.incus_bridge.ip else null;
  lokiHttpsPort = if obsNode != null then toString obsNode.services.loki.httpsPort else "3101";
  lokiUrl = if lokiIp != null then "https://${lokiIp}:${lokiHttpsPort}/loki/api/v1/push" else null;
  enableAlloy = lokiUrl != null;

  # Any host on the incus bridge or mgmt WG network can reach step-ca for
  # HTTP-01 validation (WG hosts via home-nix-0 NAT). Drive from topology
  # to avoid NixOS config self-inspection cycles.
  thisNode = topology.nodes.${config.networking.hostName} or null;
  hasInternalNetwork = thisNode != null &&
    ((thisNode.networks ? incus_bridge) || (thisNode.networks ? mgmt));
  certName = "${config.networking.hostName}.internal";
  enableClientCert = enableAlloy && hasInternalNetwork;
  certDir = "/var/lib/acme/${certName}";
in
{
  services.prometheus.exporters.node = {
    enable = true;
    openFirewall = true;
  };

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
    '';
  };

  # loki.source.journal reads via the systemd journal API — requires group access.
  # "caddy" group gives read access to the ACME cert files when client cert is enabled.
  systemd.services.alloy.serviceConfig.SupplementaryGroups = lib.mkIf enableAlloy (
    [ "systemd-journal" ] ++ lib.optional enableClientCert "caddy"
  );

  # Restart Alloy when the cert is renewed so it picks up the new key material.
  # The outer mkIf guards the entire cert key so no spurious ACME cert entry is
  # created for hosts that don't have the cert (e.g. WG-only hosts).
  security.acme.certs = lib.mkIf enableClientCert {
    ${certName}.reloadServices = [ "alloy.service" ];
  };

  # Wait for ACME cert before starting Alloy so the client cert file is present.
  systemd.services.alloy.after = lib.mkIf enableClientCert [
    "acme-${certName}.service"
  ];
  systemd.services.alloy.wants = lib.mkIf enableClientCert [
    "acme-${certName}.service"
  ];

  # alloy is DynamicUser — persist /var/lib/private/alloy (the real path), not the /var/lib/alloy symlink.
  environment.persistence."/persist".directories =
    lib.mkIf (enableAlloy && config.fileSystems ? "/persist")
      [
        {
          directory = "/var/lib/private/alloy";
          mode = "0700";
        }
      ];
}
