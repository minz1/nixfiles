{
  hostName,
  config,
  pkgs,
  lib,
  ...
}:

let
  topology = import ../../common/topology.nix;
  node = topology.nodes."${hostName}";
  wgAddr = node.networks.mgmt.ip;

  authentikNode = topology.nodes.minz-authentik-0;
  authentikIp   = authentikNode.networks.incus_bridge.ip;
  authentikPort = authentikNode.services.authentik.port;

  obsNode     = topology.nodes.minz-obs-0;
  obsIp       = obsNode.networks.incus_bridge.ip;
  grafanaPort = obsNode.services.grafana.port;

  jellyfinNode = topology.nodes.minz-jellyfin-0;
  jellyfinIp   = jellyfinNode.networks.incus_bridge.ip;
  jellyfinPort = jellyfinNode.services.jellyfin.port;
  seerrPort    = jellyfinNode.services.seerr.port;

  arrNode      = topology.nodes.minz-arr-0;
  arrIp        = arrNode.networks.incus_bridge.ip;
  sonarrPort   = arrNode.services.sonarr.port;
  radarrPort   = arrNode.services.radarr.port;
  prowlarrPort = arrNode.services.prowlarr.port;
  bazarrPort   = arrNode.services.bazarr.port;

  # Path where the firewall bouncer API key is written by the crowdsec ExecStartPre
  # script and persisted across reboots in the crowdsec state directory.
  fwBouncerKeyFile = "/var/lib/crowdsec/state/fw-bouncer.key";
in
{
  imports = [ ./hardware-configuration.nix ];

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
      port = node.services.ssh.port;
    }
  ];

  swapDevices = [
    {
      device = "/persist/swapfile";
      size = 1024;
    }
  ];

  # --- Secrets ---
  # crowdsec_caddy_api_key: generate with `openssl rand -hex 32`, add to
  # secrets/minz-vultr-nix-1.yaml before first deploy.
  sops.secrets.crowdsec_caddy_api_key = { };

  sops.templates.crowdsec-caddy-env = {
    content = "CROWDSEC_API_KEY=${config.sops.placeholder.crowdsec_caddy_api_key}";
    owner = "caddy";
    mode = "0400";
  };

  # --- CrowdSec ---
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

  # Register both bouncers in a single root (+) ExecStartPre before the LAPI
  # starts. cscli writes directly to the SQLite DB so no HTTP LAPI is needed.
  #
  # The firewall bouncer key is written to fwBouncerKeyFile (in the persisted
  # crowdsec state dir) so the bouncer service can read it via LoadCredential.
  # Using registerBouncer.enable on the bouncer module is avoided because that
  # creates a separate register service that declares StateDirectory="crowdsec",
  # which conflicts with the symlink already created by the crowdsec service
  # (status=238/STATE_DIRECTORY).
  systemd.services.crowdsec.serviceConfig.ExecStartPre = [
    "+${pkgs.writeShellScript "crowdsec-register-bouncers" ''
      cscli=/run/current-system/sw/bin/cscli
      grep=${pkgs.gnugrep}/bin/grep
      tr=${pkgs.coreutils}/bin/tr
      chmod=${pkgs.coreutils}/bin/chmod

      if ! $cscli bouncers list 2>/dev/null | $grep -q "caddy-bouncer"; then
        $cscli bouncers add "caddy-bouncer" \
          --key "$($tr -d '[:space:]' < ${config.sops.secrets.crowdsec_caddy_api_key.path})"
      fi

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
    # Key is managed by the crowdsec ExecStartPre script above.
    registerBouncer.enable = false;
    secrets.apiKeyPath = fwBouncerKeyFile;
    # api_url and mode (nftables) are derived from services.crowdsec and
    # networking.nftables.enable automatically by the module; no overrides needed.
  };

  # nftables required for the firewall bouncer's nftables backend.
  networking.nftables.enable = true;

  # --- Caddy ---
  services.caddy = {
    enable = true;
    email = "emerytang@gmail.com";
    openFirewall = true;

    # The install check looks for the plugin path in Go build info. For subpackage
    # imports (/http), build info records the root module path instead, causing a
    # false-negative. Override to skip it; the binary IS correct.
    package = (pkgs.caddy.withPlugins {
      plugins = [
        "github.com/hslatman/caddy-crowdsec-bouncer/http@v0.13.1"
      ];
      hash = "sha256-hYfokre7FwhKp6OB3/I6zH+EzXb4yoIc9JiV9b5j87Y=";
    }).overrideAttrs (_: { doInstallCheck = false; });

    globalConfig = ''
      # Required: declare crowdsec's ordering position before any route uses it.
      order crowdsec first

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
        forward_auth http://${authentikIp}:${toString authentikPort} {
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
          reverse_proxy http://${authentikIp}:${toString authentikPort}
        '';
      };

      "grafana.minz1.com" = {
        extraConfig = ''
          import security_headers
          crowdsec
          reverse_proxy http://${obsIp}:${toString grafanaPort}
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
          reverse_proxy http://${jellyfinIp}:${toString jellyfinPort}
        '';
      };

      "seerr.minz1.com" = {
        extraConfig = ''
          import security_headers
          crowdsec
          reverse_proxy http://${jellyfinIp}:${toString seerrPort}
        '';
      };

      "arr.minz1.com" = {
        extraConfig = ''
          import security_headers
          crowdsec

          handle /outpost.goauthentik.io/* {
            reverse_proxy http://${authentikIp}:${toString authentikPort}
          }

          handle /sonarr* {
            import forward_auth_authentik
            reverse_proxy http://${arrIp}:${toString sonarrPort}
          }

          handle /radarr* {
            import forward_auth_authentik
            reverse_proxy http://${arrIp}:${toString radarrPort}
          }

          handle /prowlarr* {
            import forward_auth_authentik
            reverse_proxy http://${arrIp}:${toString prowlarrPort}
          }

          handle /bazarr* {
            import forward_auth_authentik
            reverse_proxy http://${arrIp}:${toString bazarrPort}
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

  # --- Impermanence ---
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
