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
    mediaFixerPath = "/media";
    seerrIngestPath = "/ingest/seerr";
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
    };
  };
}
