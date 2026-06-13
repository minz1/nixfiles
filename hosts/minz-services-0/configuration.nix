{
  hostName,
  hostEndpoints,
  config,
  ...
}:

let
  topology = import ../../common/topology.nix;
  node = topology.nodes."${hostName}";
  servicesIp = node.networks.incus_bridge.ip;
  acmeHttpPort = 80;

  memosPort = 5230;
  caddyHttpsPort = 443;
  mediaFixerPort = 8081;

  mediaIp = topology.nodes."minz-media-0".networks.incus_bridge.ip;
  loki = hostEndpoints."minz-obs-0".loki;
in
{
  networking.hostName = hostName;
  system.stateVersion = "25.11";

  sops.secrets."media-fixer-env" = { };

  # TODO: add Caddy route for the dashboard under admin.minz1.com/media when ready.
  services.media-fixer = {
    enable = true;
    addr = ":${toString mediaFixerPort}";
    baseURL = "/media";
    environmentFile = config.sops.secrets."media-fixer-env".path;

    discord = {
      guildID = "915483669219655711";
      ownerID = "162286895827648514";
    };

    llm.model = "google/gemini-2.5-flash";

    decypharr.url = "http://${mediaIp}:8282";
    jellyfin.url = "http://${mediaIp}:8096";
    sonarr.url = "http://${mediaIp}:8989/sonarr";
    radarr.url = "http://${mediaIp}:7878/radarr";
    loki = {
      url = "https://${loki.ip}:${toString loki.port}";
      tlsCert = "/var/lib/acme/minz-services-0.internal/cert.pem";
      tlsKey = "/var/lib/acme/minz-services-0.internal/key.pem";
    };
    mediaAgent.url = "http://${mediaIp}:9191";
  };

  services.memos = {
    enable = true;
    settings = {
      MEMOS_MODE = "prod";
      MEMOS_ADDR = "127.0.0.1";
      MEMOS_PORT = toString memosPort;
      MEMOS_DATA = "/var/lib/memos/";
      MEMOS_DRIVER = "sqlite";
      MEMOS_INSTANCE_URL = "https://memos.minz1.com";
    };
  };

  services.caddy = {
    enable = true;
    settings = {
      apps = {
        tls.certificates.load_files = [
          {
            certificate = "/var/lib/acme/minz-services-0.internal/cert.pem";
            key = "/var/lib/acme/minz-services-0.internal/key.pem";
            tags = [ "memos" ];
          }
        ];
        http.servers.memos = {
          listen = [ ":${toString caddyHttpsPort}" ];
          automatic_https.disable = true;
          tls_connection_policies = [
            { certificate_selection.any_tag = [ "memos" ]; }
          ];
          routes = [
            {
              handle = [
                {
                  handler = "reverse_proxy";
                  upstreams = [ { dial = "localhost:${toString memosPort}"; } ];
                  headers.request.set."Host" = [ "{http.request.host}" ];
                }
              ];
            }
          ];
        };
      };
    };
  };

  networking.firewall.allowedTCPPorts = [
    caddyHttpsPort
    acmeHttpPort
  ];

  networking.firewall.extraCommands = ''
    iptables -A nixos-fw -s ${topology.networks.mgmt.subnet} -p tcp --dport ${toString mediaFixerPort} -j nixos-fw-accept
    iptables -A nixos-fw -s ${topology.networks.edge.subnet} -p tcp --dport ${toString mediaFixerPort} -j nixos-fw-accept
  '';

  homelab.endpoints.caddy = {
    ip = servicesIp;
    port = caddyHttpsPort;
    tls = true;
  };

  homelab.endpoints.mediafixer = {
    ip = servicesIp;
    port = mediaFixerPort;
    tls = false;
  };

  systemd.services.media-fixer.serviceConfig.SupplementaryGroups = [ "caddy" ];

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/memos";
      user = config.services.memos.user;
      group = config.services.memos.group;
      mode = "0750";
    }
    {
      directory = "/var/lib/caddy";
      user = "caddy";
      group = "caddy";
      mode = "0700";
    }
    {
      directory = "/var/lib/private/media-fixer";
      mode = "0700";
    }
  ];
}
