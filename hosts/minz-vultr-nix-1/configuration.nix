{
  hostName,
  config,
  pkgs,
  lib,
  hostEndpoints,
  ...
}:

let
  topology = import ../../common/topology.nix;
  node = topology.nodes."${hostName}";
  wgAddr = node.networks.mgmt.ip;

  authentik = hostEndpoints.minz-authentik-0.authentik;
  grafana = hostEndpoints.minz-obs-0.grafana;
  media = hostEndpoints.minz-media-0.caddy;
  memos = hostEndpoints.minz-services-0.caddy;
  mediaFixer = hostEndpoints.minz-services-0.mediafixer;

  fwBouncerKeyFile = "/var/lib/crowdsec/state/fw-bouncer.key";
  arrApps = [
    "sonarr"
    "radarr"
    "prowlarr"
    "bazarr"
  ];
in
{
  imports = [ ./hardware-configuration.nix ];

  # deprioritize wg0 to ensure edge traffic is isolated
  networking.wireguard.interfaces.wg0.metric = 100;

  networking.hostName = hostName;
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

  sops.secrets.crowdsec_caddy_api_key = { };

  sops.templates.crowdsec-caddy-env = {
    content = "CROWDSEC_API_KEY=${config.sops.placeholder.crowdsec_caddy_api_key}";
    owner = "caddy";
    mode = "0400";
  };

  services.crowdsec = {
    enable = true;
    settings = {
      lapi.credentialsFile = "/var/lib/crowdsec/state/lapi-credentials.yaml";
      general.api.server.enable = true;
    };
    hub.collections = [
      "crowdsecurity/linux"
      "crowdsecurity/caddy"
      "crowdsecurity/http-cve"
      "crowdsecurity/base-http-scenarios"
    ];
    localConfig.acquisitions = [
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

  # cscli writes directly to SQLite; registerBouncer.enable conflicts with DynamicUser symlink (status=238)
  systemd.services.crowdsec.serviceConfig.ExecStartPre = [
    "+${pkgs.writeShellScript "crowdsec-register-bouncers" ''
      cscli=/run/current-system/sw/bin/cscli
      grep=${pkgs.gnugrep}/bin/grep
      tr=${pkgs.coreutils}/bin/tr
      chmod=${pkgs.coreutils}/bin/chmod

      $cscli bouncers delete "caddy-bouncer" 2>/dev/null || true
      $cscli bouncers add "caddy-bouncer" \
        --key "$($tr -d '[:space:]' < ${config.sops.secrets.crowdsec_caddy_api_key.path})"

      if ! $cscli bouncers list 2>/dev/null | $grep -q "nftables-bouncer" \
          || [ ! -f "${fwBouncerKeyFile}" ]; then
        $cscli bouncers delete "nftables-bouncer" 2>/dev/null || true
        $cscli bouncers add "nftables-bouncer" --output raw > "${fwBouncerKeyFile}"
        $chmod 600 "${fwBouncerKeyFile}"
      fi
    ''}"
  ];

  services.crowdsec-firewall-bouncer = {
    enable = true;
    registerBouncer.enable = false;
    secrets.apiKeyPath = fwBouncerKeyFile;
  };

  networking.nftables.enable = true;

  services.caddy = {
    enable = true;
    email = "emerytang@gmail.com";
    openFirewall = true;

    # doInstallCheck=false: plugin path check false-negatives on subpackage imports.
    package =
      (pkgs.caddy.withPlugins {
        plugins = [
          "github.com/hslatman/caddy-crowdsec-bouncer/http@v0.13.1"
        ];
        hash = "sha256-9wxFVwd+s3woOvX5n7U+FEpw9Sri4b9SEftpSSOAArk=";
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
        }
      }
    '';

    virtualHosts = {
      "auth.minz1.com" = {
        extraConfig = ''
          import security_headers
          crowdsec
          reverse_proxy https://${authentik.ip}:${toString authentik.port} {
            header_up Host {http.request.host}
          }
        '';
      };

      "grafana.minz1.com" = {
        extraConfig = ''
          import security_headers
          crowdsec
          reverse_proxy https://${grafana.ip}:${toString grafana.port} {
            header_up Host {http.request.host}
          }
        '';
      };

      # X-Frame-Options omitted: Jellyfin uses iframes for some player views.
      "jellyfin.minz1.com" = {
        extraConfig = ''
          header {
            Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
            X-Content-Type-Options "nosniff"
            Referrer-Policy "strict-origin-when-cross-origin"
            -Server
          }
          crowdsec
          reverse_proxy https://${media.ip}:${toString media.port} {
            header_up Host {http.request.host}
            flush_interval -1
          }
        '';
      };

      "seerr.minz1.com" = {
        extraConfig = ''
          import security_headers
          crowdsec
          reverse_proxy https://${media.ip}:${toString media.port} {
            header_up Host {http.request.host}
          }
        '';
      };

      "memos.minz1.com" = {
        extraConfig = ''
          import security_headers
          crowdsec
          reverse_proxy https://${memos.ip}:${toString memos.port} {
            header_up Host {http.request.host}
          }
        '';
      };

      "admin.minz1.com" = {
        extraConfig = ''
          import security_headers
          crowdsec

          handle /outpost.goauthentik.io/* {
            reverse_proxy https://${authentik.ip}:${toString authentik.port}
          }

          handle /media* {
            import forward_auth_authentik
            reverse_proxy http://${mediaFixer.ip}:${toString mediaFixer.port} {
              header_up Host {http.request.host}
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
            reverse_proxy https://${authentik.ip}:${toString authentik.port}
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
    };

    environmentFile = config.sops.templates.crowdsec-caddy-env.path;
  };

  systemd.services.caddy.after = lib.mkAfter [ "crowdsec.service" ];
  systemd.services.caddy.requires = [ "crowdsec.service" ];

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/caddy";
      user = "caddy";
      group = "caddy";
      mode = "0700";
    }
    # CrowdSec uses DynamicUser; real state is at /var/lib/private/crowdsec.
    {
      directory = "/var/lib/private/crowdsec";
      mode = "0700";
    }
  ];
}
