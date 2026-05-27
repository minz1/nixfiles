{ hostName, config, lib, ... }:

let
  topology = import ../../common/topology.nix;
  node = topology.nodes."${hostName}";
  vmIp = node.networks.incus_bridge.ip;
  promPort = node.services.prometheus.port;
  lokiPort = node.services.loki.port;
  grafanaPort = node.services.grafana.port;

  nixosNodes = lib.filterAttrs (_: n: n.os == "nixos") topology.nodes;
  nodeExporterTargets = lib.mapAttrsToList (_: n:
    let ip = if n.networks ? incus_bridge
             then n.networks.incus_bridge.ip
             else n.networks.mgmt.ip;
    in "${ip}:9100"
  ) nixosNodes;
in
{
  networking.hostName = hostName;
  system.stateVersion = "25.11";

  sops.defaultSopsFile = ../../secrets/minz-obs-0.yaml;

  services.prometheus = {
    enable = true;
    port = promPort;
    retentionTime = "30d";
    scrapeConfigs = [
      {
        job_name = "node";
        static_configs = [{ targets = nodeExporterTargets; }];
      }
      {
        job_name = "prometheus";
        static_configs = [{ targets = [ "127.0.0.1:${toString promPort}" ]; }];
      }
      {
        job_name = "loki";
        static_configs = [{ targets = [ "127.0.0.1:${toString lokiPort}" ]; }];
      }
    ];
  };

  services.loki = {
    enable = true;
    configuration = {
      auth_enabled = false;
      server = {
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
      limits_config.retention_period = "30d";
      compactor = {
        working_directory = "/var/lib/loki/compactor";
        retention_enabled = true;
        delete_request_store = "filesystem";
      };
      analytics.reporting_enabled = false;
    };
  };

  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_addr = "0.0.0.0";
        http_port = grafanaPort;
        domain = vmIp;
        root_url = "http://${vmIp}:${toString grafanaPort}/";
      };
      security = {
        admin_user = "admin";
        # $__file{} is expanded by Grafana's file provider at runtime.
        admin_password = "$__file{${config.sops.secrets.grafana_admin_password.path}}";
        secret_key = "$__file{${config.sops.secrets.grafana_secret_key.path}}";
      };
      analytics = {
        reporting_enabled = false;
        check_for_updates = false;
      };
      # auth.generic_oauth placeholder — wired to authentik in phase 5e.
    };
    provision = {
      enable = true;
      datasources.settings.datasources = [
        {
          name = "Prometheus";
          type = "prometheus";
          url = "http://127.0.0.1:${toString promPort}";
          isDefault = true;
        }
        {
          name = "Loki";
          type = "loki";
          url = "http://127.0.0.1:${toString lokiPort}";
        }
      ];
    };
  };

  sops.secrets.grafana_admin_password = {
    mode = "0400";
    owner = "grafana";
  };

  sops.secrets.grafana_secret_key = {
    mode = "0400";
    owner = "grafana";
  };

  swapDevices = [{ device = "/persist/swapfile"; size = 2048; }];

  networking.firewall.allowedTCPPorts = [
    promPort
    lokiPort
    grafanaPort
  ];

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/prometheus2";
      user = "prometheus";
      group = "prometheus";
      mode = "0750";
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
