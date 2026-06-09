{
  hostName,
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
in
{
  networking.hostName = hostName;
  system.stateVersion = "25.11";

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

  security.acme = {
    certs."minz-services-0.internal" = {
      listenHTTP = ":${toString acmeHttpPort}";
      reloadServices = [ "caddy.service" ];
      group = "caddy";
      extraDomainNames = [ servicesIp ];
    };
  };

  networking.firewall.allowedTCPPorts = [
    caddyHttpsPort
    acmeHttpPort
  ];

  homelab.endpoints.caddy = {
    ip = servicesIp;
    port = caddyHttpsPort;
    tls = true;
  };

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
  ];
}
