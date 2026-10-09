{
  hostName,
  hostEndpoints,
  config,
  topology,
  node,
  ...
}:

let
  servicesIp = node.networks.incus_bridge.ip;

  caddyHttpsPort = 443;
  mediaFixerPort = 8081;
  ntfyPort = 2586; # module default listen-http = "127.0.0.1:2586"

  mediaIp = topology.nodes."minz-media-0".networks.incus_bridge.ip;
  loki = hostEndpoints."minz-obs-0".loki;
in
{
  system.stateVersion = "25.11";

  # Go caches the TLS cert pool at startup; try-reload-or-restart triggers a full restart for services without ExecReload, which is what we need after cert renewal.
  security.acme.certs."${hostName}.internal".reloadServices = [ "media-fixer.service" ];

  sops.secrets."media-fixer-env".restartUnits = [
    "media-fixer.service"
  ];

  services.media-fixer = {
    enable = true;
    # loopback only: reachable solely through Caddy's mTLS-gated admin.minz1.com route below
    addr = "127.0.0.1:${toString mediaFixerPort}";
    baseURL = "/media";
    environmentFile = config.sops.secrets."media-fixer-env".path;

    discord = {
      guildID = "915483669219655711";
      ownerID = "162286895827648514";
    };

    llm.model = "google/gemini-2.5-flash";

    decypharr.url = "https://${mediaIp}:8443";
    jellyfin.url = "https://${mediaIp}:8920";
    sonarr.url = "https://${mediaIp}/sonarr";
    radarr.url = "https://${mediaIp}/radarr";
    loki = {
      url = "https://${loki.ip}:${toString loki.port}";
      tlsCert = "/var/lib/acme/minz-services-0.internal/cert.pem";
      tlsKey = "/var/lib/acme/minz-services-0.internal/key.pem";
    };
    mediaAgent.url = "https://${mediaIp}:9443";
  };

  # bcrypt HASHES (from `ntfy user hash`), not plaintext — obs-0 holds the plaintext counterpart
  sops.secrets."ntfy_grafana_password_hash" = { };
  sops.secrets."ntfy_phone_password_hash" = { };

  sops.templates."ntfy-env" = {
    restartUnits = [
      "ntfy-sh.service"
    ];
    content = ''
      NTFY_AUTH_USERS='grafana:${config.sops.placeholder.ntfy_grafana_password_hash}:user,phone:${config.sops.placeholder.ntfy_phone_password_hash}:user'
      NTFY_AUTH_ACCESS='grafana:homelab-alerts:write-only,phone:homelab-alerts:read-only'
    '';
  };

  services.ntfy-sh = {
    enable = true;
    settings = {
      base-url = "https://ntfy.minz1.com";
      # per-visitor rate limiting; without this every request looks like it's from Caddy's loopback
      behind-proxy = true;
      # default is read-write; unset this and the topic is world-publishable once the vhost exists
      auth-default-access = "deny-all";
      # iOS can't hold a background connection; relays a poll_request (message ID + topic hash only, not content) to ntfy.sh so it can push via APNS
      upstream-base-url = "https://ntfy.sh";
    };
    environmentFile = config.sops.templates."ntfy-env".path;
  };

  services.caddy = {
    enable = true;
    settings = {
      apps = {
        tls.certificates.load_files = [
          {
            certificate = "/var/lib/acme/minz-services-0.internal/cert.pem";
            key = "/var/lib/acme/minz-services-0.internal/key.pem";
            tags = [ "services" ];
          }
        ];
        http.servers.services = {
          listen = [ ":${toString caddyHttpsPort}" ];
          automatic_https.disable = true;
          # the edge dials by IP (no SNI); client auth would otherwise auto-enable strict SNI and 421 every
          # proxied Host. The admin route authorizes on the client cert CN, not SNI.
          strict_sni_host = false;
          tls_connection_policies = [
            {
              certificate_selection.any_tag = [ "services" ];
              # ntfy clients don't present one; the admin route below requires it
              client_authentication = {
                trusted_ca_certs_pem_files = [ "/etc/ssl/internal-ca.crt" ];
                mode = "verify_if_given";
              };
            }
          ];
          routes = [
            {
              # media-fixer has no auth of its own (its approval endpoint gates destructive agent
              # actions), so only the edge — which enforces Authentik forward_auth — gets through
              match = [ { host = [ "admin.minz1.com" ]; } ];
              handle = [
                {
                  handler = "subroute";
                  routes = [
                    {
                      match = [
                        {
                          not = [
                            { expression = ''{http.request.tls.client.subject} == "CN=minz-vultr-nix-1.internal"''; }
                          ];
                        }
                      ];
                      handle = [
                        {
                          handler = "static_response";
                          status_code = 403;
                        }
                      ];
                    }
                    {
                      handle = [
                        {
                          handler = "reverse_proxy";
                          upstreams = [ { dial = "127.0.0.1:${toString mediaFixerPort}"; } ];
                          headers.request.set."Host" = [ "{http.request.host}" ];
                        }
                      ];
                    }
                  ];
                }
              ];
            }
            {
              # .internal alias lets Grafana publish over the bridge instead of hairpinning through the edge
              match = [
                {
                  host = [
                    "ntfy.minz1.com"
                    "minz-services-0.internal"
                  ];
                }
              ];
              handle = [
                {
                  handler = "reverse_proxy";
                  upstreams = [ { dial = "localhost:${toString ntfyPort}"; } ];
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
  ];

  homelab.endpoints.caddy = {
    ip = servicesIp;
    port = caddyHttpsPort;
  };

  systemd.services.media-fixer.serviceConfig.SupplementaryGroups = [ "caddy" ];

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/private/media-fixer";
      mode = "0700";
    }
    # DynamicUser: persist /var/lib/private/ntfy-sh, not the /var/lib/ntfy-sh symlink.
    {
      directory = "/var/lib/private/ntfy-sh";
      mode = "0700";
    }
  ];

  homelab.backups.targets.services-state = {
    paths = [
      "/var/lib/private/ntfy-sh"
      "/var/lib/private/media-fixer"
    ];
    timerConfig = {
      OnCalendar = "*-*-* 05:00:00";
      RandomizedDelaySec = "30m";
      Persistent = true;
    };
  };
}
