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
    step-ca = {
      host = minz-pki-0.name;
      port = 9443;
    };
    rustfs = {
      host = minz-vultr-nix-0.name;
      port = 9000;
    };
    forgejo = {
      host = minz-vultr-nix-0.name;
      port = 3000;
    };
    minecraft = {
      host = minz-game-0.name;
      port = 25565;
    };
    decypharr-ui = {
      host = minz-media-0.name;
      port = 8443;
    };
    jellyfin-api = {
      host = minz-media-0.name;
      port = 8920;
    };
    media-agent = {
      host = minz-media-0.name;
      port = 9443;
    };
    authentik-ldaps = {
      host = minz-authentik-0.name;
      port = 6636;
    };
    minecraft-rcon = {
      host = minz-game-0.name;
      port = 25575;
    };
    game-caddy = {
      host = minz-game-0.name;
      port = 443;
    };
  };
  hostPorts.node-exporter = 9100;
}
