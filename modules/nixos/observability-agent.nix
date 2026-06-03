{ config, lib, ... }:

let
  topology = import ../../common/topology.nix;
  obsNode = topology.nodes."minz-obs-0" or null;
  lokiIp = if obsNode != null then obsNode.networks.incus_bridge.ip else null;
  lokiPort = if obsNode != null then toString obsNode.services.loki.port else "3100";
  lokiUrl = if lokiIp != null then "http://${lokiIp}:${lokiPort}/loki/api/v1/push" else null;
  enableAlloy = lokiUrl != null;
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
        }
      }
    '';
  };

  # loki.source.journal reads via the systemd journal API — requires group access.
  systemd.services.alloy.serviceConfig.SupplementaryGroups = lib.mkIf enableAlloy [
    "systemd-journal"
  ];

  # alloy is DynamicUser — persist /var/lib/private/alloy (the real path), not the /var/lib/alloy symlink.
  environment.persistence."/persist".directories = lib.mkIf (enableAlloy && config.fileSystems ? "/persist") [
    {
      directory = "/var/lib/private/alloy";
      mode = "0700";
    }
  ];
}
