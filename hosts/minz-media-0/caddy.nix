{
  config,
  lib,
  topology,
  fleet,
  node,
  ...
}:

let
  mediaIp = node.networks.incus_bridge.ip;
  caddyHttpsPort = topology.services.media-caddy.port;
  jellyfinPort = 8096;
  mediaAgentPort = 9191;
  seerrPort = 5055;
  sonarrPort = 8989;
  radarrPort = 7878;
  prowlarrPort = 9696;
  bazarrPort = 6767;
  decypharrPort = 8282;
  decypharrUiPort = topology.services.decypharr-ui.port;
  jellyfinApiPort = topology.services.jellyfin-api.port;
  jellyfinProxy = {
    handler = "reverse_proxy";
    upstreams = [ { dial = "127.0.0.1:${toString jellyfinPort}"; } ];
    flush_interval = -1;
  };
  mediaAgentHttpsPort = topology.services.media-agent.port;
  adminIps = map (n: topology.nodes.${n}.networks.mgmt.ip) (fleet.withRole "admin-client");
  servicesIp = topology.nodes.${topology.services.services-caddy.host}.networks.incus_bridge.ip;
in
{
  imports = [
    {
      services.caddy.settings.apps.http.servers =
        lib.mapAttrs
          (_: proxy: {
            listen = [ ":${toString proxy.port}" ];
            automatic_https.disable = true;
            tls_connection_policies = [
              { certificate_selection.any_tag = [ "media" ]; }
            ];
            routes = [
              {
                handle = [
                  {
                    handler = "reverse_proxy";
                    upstreams = [ { dial = "127.0.0.1:${toString proxy.upstream}"; } ];
                    flush_interval = -1;
                  }
                ];
              }
            ];
          })
          {
            decypharr-ui = {
              port = decypharrUiPort;
              upstream = decypharrPort;
            };
            jellyfin-api = {
              port = jellyfinApiPort;
              upstream = jellyfinPort;
            };
            media-agent = {
              port = mediaAgentHttpsPort;
              upstream = mediaAgentPort;
            };
          };
    }
  ];

  services.caddy = {
    enable = true;
    settings = {
      apps = {
        tls.certificates.load_files = [
          {
            certificate = "/var/lib/acme/minz-media-0.internal/cert.pem";
            key = "/var/lib/acme/minz-media-0.internal/key.pem";
            tags = [ "media" ];
          }
        ];
        http.servers.main = {
          listen = [ ":${toString caddyHttpsPort}" ];
          automatic_https.disable = true;
          tls_connection_policies = [
            { certificate_selection.any_tag = [ "media" ]; }
          ];
          routes = [
            # Nix store files are dated 1970, so without this browsers cache /web/ for years.
            {
              match = [
                {
                  host = [ "jellyfin.minz1.com" ];
                  path = [ "/web/*" ];
                }
              ];
              handle = [ (jellyfinProxy // { headers.response.set."Cache-Control" = [ "no-cache" ]; }) ];
            }
            {
              match = [ { host = [ "jellyfin.minz1.com" ]; } ];
              handle = [ jellyfinProxy ];
            }
            # Path-specific routes before the seerr catch-all; mediaIp allows direct WireGuard access (e.g. from the Tofu runner at https://10.10.0.7/sonarr).
          ]
          ++
            map
              (app: {
                match = [
                  {
                    host = [
                      "arr.minz1.com"
                      mediaIp
                    ];
                    path = [ "/${app.name}*" ];
                  }
                ];
                handle = [
                  {
                    handler = "reverse_proxy";
                    upstreams = [ { dial = "127.0.0.1:${toString app.port}"; } ];
                  }
                ];
              })
              [
                {
                  name = "sonarr";
                  port = sonarrPort;
                }
                {
                  name = "radarr";
                  port = radarrPort;
                }
                {
                  name = "prowlarr";
                  port = prowlarrPort;
                }
                {
                  name = "bazarr";
                  port = bazarrPort;
                }
              ]
          ++ [
            # radarr v2.3.5 strips base path from provider URL, producing bare /api/v3/* requests
            {
              match = [
                {
                  host = [ mediaIp ];
                  path = [ "/api/v3*" ];
                }
              ];
              handle = [
                {
                  handler = "reverse_proxy";
                  upstreams = [ { dial = "127.0.0.1:${toString radarrPort}"; } ];
                }
              ];
            }
            # catch-all; must follow path routes so /sonarr*, /radarr* etc. don't land here
            {
              match = [
                {
                  host = [
                    "seerr.minz1.com"
                    mediaIp
                  ];
                }
              ];
              handle = [
                {
                  handler = "reverse_proxy";
                  upstreams = [ { dial = "127.0.0.1:${toString seerrPort}"; } ];
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
  ];

  networking.firewall.extraCommands =
    lib.concatMapStrings (
      ip: "iptables -A nixos-fw -s ${ip} -p tcp --dport ${toString decypharrUiPort} -j nixos-fw-accept\n"
    ) adminIps
    + ''
      iptables -A nixos-fw -s ${servicesIp} -p tcp --dport ${toString decypharrUiPort} -j nixos-fw-accept
      iptables -A nixos-fw -s ${servicesIp} -p tcp --dport ${toString jellyfinApiPort} -j nixos-fw-accept
      iptables -A nixos-fw -s ${servicesIp} -p tcp --dport ${toString mediaAgentHttpsPort} -j nixos-fw-accept
    '';
}
