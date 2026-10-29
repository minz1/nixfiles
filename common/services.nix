{ config, ... }:
with config.nodes;
{
  services = {
    attic = {
      host = minz-attic-0.name;
      port = 443;
    };
    authentik = {
      host = minz-authentik-0.name;
      port = 9443;
    };
    grafana = {
      host = minz-obs-0.name;
      port = 3443;
    };
    loki = {
      host = minz-obs-0.name;
      port = 3101;
    };
    media-caddy = {
      host = minz-media-0.name;
      port = 443;
    };
    services-caddy = {
      host = minz-services-0.name;
      port = 443;
    };
  };
}
