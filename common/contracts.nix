{ config, ... }:
let
  hosts = config.contracts.publicHosts;
in
{
  contracts = {
    publicHosts = {
      auth = "auth.minz1.com";
      grafana = "grafana.minz1.com";
      seerr = "seerr.minz1.com";
      arr = "arr.minz1.com";
      admin = "admin.minz1.com";
      jellyfin = "jellyfin.minz1.com";
      ntfy = "ntfy.minz1.com";
      books = "books.minz1.com";
      bindery = "bindery.minz1.com";
    };
    oidc.grafana = {
      clientId = "grafana";
      redirectUris = [ "https://${hosts.grafana}/login/generic_oauth" ];
      adminGroup = "grafana-admins";
    };
    oidc.seerr = {
      clientId = "seerr";
      redirectUris = [ "https://${hosts.seerr}/login" ];
    };
    oidc.audiobookshelf = {
      clientId = "audiobookshelf";
      redirectUris = [
        "https://${hosts.books}/auth/openid/callback"
        "https://${hosts.books}/auth/openid/mobile-redirect"
      ];
    };
    oidc.bindery = {
      clientId = "bindery";
      providerId = "authentik";
      redirectUris = [ "https://${hosts.bindery}/api/v1/auth/oidc/authentik/callback" ];
    };
    mediaFixerPath = "/media";
    seerrIngestPath = "/ingest/seerr";
    sonarrIngestPath = "/ingest/sonarr";
    bazarrIngestPath = "/ingest/bazarr";
    localPorts.minz-media-0 = {
      sonarr = {
        port = 8989;
        urlBase = "/sonarr";
      };
      radarr = {
        port = 7878;
        urlBase = "/radarr";
      };
      prowlarr = {
        port = 9696;
        urlBase = "/prowlarr";
      };
      jellyfin.port = 8096;
      decypharr.port = 8282;
      media-agent.port = 9191;
      seadexerr.port = 6868;
      zilean.port = 8181;
      comet.port = 8000;
      flaresolverr.port = 8191;
      audiobookshelf.port = 13378;
      bindery.port = 8787;
    };
  };
}
