{
  hostName,
  config,
  pkgs,
  lib,
  hostEndpoints,
  topology,
  node,
  mkHardened,
  ...
}:

let
  wgAddr = node.networks.mgmt.ip;

  authentik = hostEndpoints.minz-authentik-0.authentik;
  grafana = hostEndpoints.minz-obs-0.grafana;
  media = hostEndpoints.minz-media-0.caddy;
  servicesCaddy = hostEndpoints.minz-services-0.caddy;

  arrApps = [
    "sonarr"
    "radarr"
    "prowlarr"
    "bazarr"
  ];

  gameIp = topology.nodes."minz-game-0".networks.incus_bridge.ip;
  gamePort = 25565;

  # own Caddy holds :80 for its own public ACME; internal-cert ACME (lego) gets this local port instead, fronted by the :80 catch-all below
  internalAcmeHttpPort = 18080;
  velocityPort = 25565;

  velocityToml = pkgs.replaceVars ./velocity.toml {
    inherit gameIp;
    gamePort = toString gamePort;
    velocityPort = toString velocityPort;
  };

  # transport block presenting this host's own internal cert as a client cert; needed for
  # every callee that now requires mTLS (Authentik, Grafana behind obs-0's Caddy).
  clientAuthTransport = ''
    transport http {
      tls
      tls_client_auth /var/lib/acme/${hostName}.internal/cert.pem /var/lib/acme/${hostName}.internal/key.pem
      tls_trust_pool file /etc/ssl/internal-ca.crt
    }
  '';

  mkProxyVhost =
    {
      endpoint,
      headers ? "import security_headers",
      extra ? null,
      clientAuth ? false,
    }:
    {
      extraConfig = ''
        ${headers}
        crowdsec
        reverse_proxy https://${endpoint.ip}:${toString endpoint.port} {
          header_up Host {http.request.host}${lib.optionalString (extra != null) "\n  ${extra}"}
          ${lib.optionalString clientAuth clientAuthTransport}
        }
      '';
    };
in
{
  imports = [ ./hardware-configuration.nix ];

  # deprioritize wg0 to ensure edge traffic is isolated
  networking.wireguard.interfaces.wg0.metric = 100;

  system.stateVersion = "25.11";

  systemd.network.networks."20-enp1s0" = {
    matchConfig.Name = "enp1s0";
    networkConfig.DHCP = "ipv4";
    linkConfig.RequiredForOnline = "routable";
  };

  services.openssh.listenAddresses = [
    {
      addr = wgAddr;
      port = 22;
    }
  ];

  swapDevices = [
    {
      device = "/persist/swapfile";
      size = 1024;
    }
  ];

  sops.secrets.crowdsec_caddy_api_key = {
    owner = "crowdsec";
    restartUnits = [ "crowdsec.service" ];
  };

  sops.secrets.minecraft_velocity_forwarding_secret = { };

  sops.templates.crowdsec-caddy-env = {
    # consumed by caddy's environmentFile (the bouncer plugin), not crowdsec itself
    restartUnits = [
      "caddy.service"
    ];
    content = "CROWDSEC_API_KEY=${config.sops.placeholder.crowdsec_caddy_api_key}";
    owner = "caddy";
  };

  services.crowdsec = {
    enable = true;
    hub.collections = [
      "crowdsecurity/linux"
      "crowdsecurity/caddy"
      "crowdsecurity/http-cve"
      "crowdsecurity/base-http-scenarios"
    ];
    settings.acquisitions = [
      {
        source = "journalctl";
        journalctl_filter = [ "_SYSTEMD_UNIT=caddy.service" ];
        labels.type = "caddy";
      }
      {
        source = "journalctl";
        journalctl_filter = [ "_SYSTEMD_UNIT=sshd.service" ];
        labels.type = "syslog";
      }
    ];
  };

  # the caddy bouncer's key is fixed in sops, so it is registered with that key rather than via cscli's generated one
  systemd.services.crowdsec.serviceConfig.ExecStartPre = [
    "${pkgs.writeShellScript "crowdsec-register-bouncers" ''
      cscli=/run/current-system/sw/bin/cscli
      tr=${pkgs.coreutils}/bin/tr

      $cscli bouncers delete "caddy-bouncer" 2>/dev/null || true
      $cscli bouncers add "caddy-bouncer" \
        --key "$($tr -d '[:space:]' < ${config.sops.secrets.crowdsec_caddy_api_key.path})"
    ''}"
  ];

  # on a live switch the /var/lib/crowdsec bind mount appears after tmpfiles ran; crowdsec-setup's own namespace needs data/ to exist, so this runs outside it
  systemd.services.crowdsec-data-dirs = {
    requiredBy = [ "crowdsec-setup.service" ];
    before = [ "crowdsec-setup.service" ];
    unitConfig.RequiresMountsFor = [ "/var/lib/crowdsec" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${config.systemd.package}/bin/systemd-tmpfiles --create --prefix=/var/lib/crowdsec";
    };
  };

  services.crowdsec-firewall-bouncer.enable = true;

  networking.nftables.enable = true;

  # Caddy already owns :80 for its own public ACME; lego listens locally and Caddy relays the challenge
  security.acme.certs."${hostName}.internal".listenHTTP =
    "127.0.0.1:${toString internalAcmeHttpPort}";
  # step-ca validates HTTP-01 once; at boot the order must not start before Caddy relays :80
  systemd.services."acme-order-renew-${hostName}.internal".after = [ "caddy.service" ];

  services.caddy = {
    enable = true;
    email = "emerytang@gmail.com";
    openFirewall = true;

    package =
      (pkgs.caddy.withPlugins {
        plugins = [
          "github.com/hslatman/caddy-crowdsec-bouncer/http@v0.14.1"
        ];
        hash = "sha256-P3TKSvV3cfH8o4sG/DiuVz5HCdY74VTcKLTlss+dHe4=";
      }).overrideAttrs
        (_: {
          doInstallCheck = false;
        });

    globalConfig = ''
      order crowdsec first
      # disable_redirects: lets lego own port 80 for step-ca ACME issuance
      auto_https disable_redirects

      crowdsec {
        api_url http://127.0.0.1:8080
        api_key {$CROWDSEC_API_KEY}
        ticker_interval 15s
      }
    '';

    extraConfig = ''
      (security_headers) {
        header {
          Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
          X-Frame-Options "SAMEORIGIN"
          X-Content-Type-Options "nosniff"
          Referrer-Policy "strict-origin-when-cross-origin"
          -Server
        }
      }

      (forward_auth_authentik) {
        forward_auth https://${authentik.ip}:${toString authentik.port} {
          uri /outpost.goauthentik.io/auth/caddy
          copy_headers X-authentik-username X-authentik-groups X-authentik-email X-authentik-name X-authentik-uid
          ${clientAuthTransport}
        }
      }
    '';

    virtualHosts = {
      "auth.minz1.com" = mkProxyVhost {
        endpoint = authentik;
        clientAuth = true;
      };

      "grafana.minz1.com" = mkProxyVhost {
        endpoint = grafana;
        clientAuth = true;
      };

      # X-Frame-Options omitted: Jellyfin uses iframes for some player views.
      "jellyfin.minz1.com" = mkProxyVhost {
        endpoint = media;
        headers = ''
          header {
            Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
            X-Content-Type-Options "nosniff"
            Referrer-Policy "strict-origin-when-cross-origin"
            -Server
          }'';
        extra = "flush_interval -1";
      };

      "seerr.minz1.com" = mkProxyVhost { endpoint = media; };

      # routed by Host header to the ntfy route on services-0's shared Caddy instance
      "ntfy.minz1.com" = mkProxyVhost {
        endpoint = servicesCaddy;
        # ntfy subscriptions are long-lived streams; without this Caddy buffers them.
        extra = "flush_interval -1";
      };

      "admin.minz1.com" = {
        extraConfig = ''
          import security_headers
          crowdsec

          handle /outpost.goauthentik.io/* {
            reverse_proxy https://${authentik.ip}:${toString authentik.port} {
              ${clientAuthTransport}
            }
          }

          handle /media* {
            import forward_auth_authentik
            reverse_proxy https://${servicesCaddy.ip}:${toString servicesCaddy.port} {
              header_up Host {http.request.host}
              ${clientAuthTransport}
            }
          }

          handle {
            respond "Not found" 404
          }
        '';
      };

      "arr.minz1.com" = {
        extraConfig = ''
          import security_headers
          crowdsec

          handle /outpost.goauthentik.io/* {
            reverse_proxy https://${authentik.ip}:${toString authentik.port} {
              ${clientAuthTransport}
            }
          }

          ${lib.concatMapStrings (app: ''
            handle /${app}* {
              import forward_auth_authentik
              reverse_proxy https://${media.ip}:${toString media.port} {
                header_up Host {http.request.host}
              }
            }
          '') arrApps}

          handle {
            respond "Not found" 404
          }
        '';
      };

      # catch-all, no Host match: relays the internal-cert ACME challenge; named vhosts above still win their own ACME via automatic HTTPS
      ":80" = {
        extraConfig = ''
          handle /.well-known/acme-challenge/* {
            reverse_proxy 127.0.0.1:${toString internalAcmeHttpPort}
          }

          handle {
            respond "Not found" 404
          }
        '';
      };
    };

    environmentFile = config.sops.templates.crowdsec-caddy-env.path;
  };

  systemd.services.caddy.after = lib.mkAfter [ "crowdsec.service" ];
  systemd.services.caddy.requires = [ "crowdsec.service" ];

  systemd.services.velocity = {
    description = "Velocity Minecraft proxy";
    after = [
      "network.target"
      "wireguard-wg1.service"
    ];
    wants = [ "wireguard-wg1.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig =
      mkHardened {
        capabilityBoundingSet = [ "CAP_DAC_OVERRIDE" ];
        ambientCapabilities = [ "CAP_DAC_OVERRIDE" ];
        privateUsers = false;
      }
      // {
        DynamicUser = true;
        StateDirectory = "velocity";
        WorkingDirectory = "/var/lib/velocity";
        ExecStartPre = [
          # No +: runs as DynamicUser so velocity.toml is owned by that UID and Velocity can write back for config migrations.
          "${pkgs.coreutils}/bin/install -m 644 ${velocityToml} /var/lib/velocity/velocity.toml"
          # + required: forwarding.secret is a sops path readable only by root.
          "+${pkgs.coreutils}/bin/install -m 644 ${config.sops.secrets.minecraft_velocity_forwarding_secret.path} /var/lib/velocity/forwarding.secret"
        ];
        ExecStart = "${pkgs.velocity}/bin/velocity -Dvelocity.max-known-packs=1024 -Dvelocity.max-plugin-message-payload-size=16777216";
        Restart = "on-failure";
        RestartSec = "5s";
      };
  };

  networking.firewall.allowedTCPPorts = [ velocityPort ];

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/crowdsec";
      user = "crowdsec";
      group = "crowdsec";
      mode = "0750";
    }
    # Velocity uses DynamicUser (real state at /var/lib/private/velocity) — persisting avoids losing logs across reboots; config is re-written by ExecStartPre.
    {
      directory = "/var/lib/private/velocity";
      mode = "0700";
    }
  ];
}
