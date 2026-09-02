{
  hostName,
  config,
  pkgs,
  lib,
  authentik-nix,
  ...
}:

let
  mkHardened = import ../../modules/lib/hardening.nix { inherit lib; };
  topology = import ../../common/topology.nix;
  node = topology.nodes."${hostName}";
  authentikIp = node.networks.incus_bridge.ip;
  acmeHttpPort = 80;

  authentikPort = 9000;
  authentikHttpsPort = 9443;
  ldapPort = 3389;
  ldapTlsPort = 6636;
  # +1: Caddy owns the external ports; outpost listeners must not conflict
  authentikBuiltinHttpsPort = authentikHttpsPort + 1;
  ldapOutpostTlsPort = ldapTlsPort + 1;
in
{
  imports = [
    authentik-nix.nixosModules.default
  ];

  networking.hostName = hostName;
  system.stateVersion = "25.11";

  sops.secrets.authentik_env.mode = "0400";
  sops.secrets.authentik_ldap_token.mode = "0400";

  sops.templates.authentik-ldap-env = {
    content = ''
      AUTHENTIK_HOST=http://localhost:${toString authentikPort}
      AUTHENTIK_INSECURE=false
      AUTHENTIK_TOKEN=${config.sops.placeholder.authentik_ldap_token}
      AUTHENTIK_LISTEN__LDAPS=127.0.0.1:${toString ldapOutpostTlsPort}
    '';
    mode = "0400";
  };

  services.authentik = {
    enable = true;
    environmentFile = config.sops.secrets.authentik_env.path;
    settings = {
      disable_startup_analytics = true;
      avatars = "none";
      email = {
        host = "smtp.resend.com";
        port = 587;
        username = "resend";
        use_tls = true;
        use_ssl = false;
        from = "noreply@minz1.com";
      };
    };
  };

  systemd.services.authentik.environment.AUTHENTIK_LISTEN__HTTPS =
    "127.0.0.1:${toString authentikBuiltinHttpsPort}";
  systemd.services.caddy.after = lib.mkAfter [ "authentik-ldap.service" ];

  services.authentik-ldap = {
    enable = true;
    environmentFile = config.sops.templates.authentik-ldap-env.path;
  };

  systemd.services.authentik-ldap.restartTriggers = [
    config.sops.templates.authentik-ldap-env.content
  ];

  services.caddy = {
    enable = true;
    package = pkgs.caddy.withPlugins {
      plugins = [ "github.com/mholt/caddy-l4@v0.1.2" ];
      hash = "sha256-C+ksbA6ucY3GUsYHSUhkYoh1gTP8SIAJv0MLjhX8BQM=";
    };

    settings = {
      apps = {
        tls = {
          certificates = {
            load_files = [
              {
                certificate = "/var/lib/acme/minz-authentik-0.internal/cert.pem";
                key = "/var/lib/acme/minz-authentik-0.internal/key.pem";
                tags = [ "authentik" ];
              }
            ];
          };
        };
        http = {
          servers = {
            authentik = {
              listen = [ ":${toString authentikHttpsPort}" ];
              automatic_https.disable = true;
              tls_connection_policies = [
                { certificate_selection.any_tag = [ "authentik" ]; }
              ];
              routes = [
                {
                  handle = [
                    {
                      handler = "reverse_proxy";
                      upstreams = [ { dial = "localhost:${toString authentikPort}"; } ];
                      # preserve X-Forwarded-Host from edge Caddy; overwriting breaks outpost proxy provider matching
                      headers.request.set."X-Forwarded-Host" = [ "{http.request.header.X-Forwarded-Host}" ];
                    }
                  ];
                }
              ];
            };
          };
        };
        layer4 = {
          servers = {
            ldaps = {
              listen = [ "0.0.0.0:${toString ldapTlsPort}" ];
              routes = [
                {
                  handle = [
                    { handler = "tls"; }
                    {
                      handler = "proxy";
                      upstreams = [ { dial = [ "localhost:${toString ldapPort}" ]; } ];
                    }
                  ];
                }
              ];
            };
          };
        };
      };
    };
  };

  swapDevices = [
    {
      device = "/persist/swapfile";
      size = 2048;
    }
  ];

  networking.firewall.allowedTCPPorts = [
    authentikHttpsPort
    ldapTlsPort
    acmeHttpPort
  ];

  systemd.services.authentik.serviceConfig = mkHardened {
    privateUsers = false;
    extraSystemCallFilter = [ "@chown" ];
  };

  systemd.services.authentik-worker.serviceConfig = mkHardened {
    privateUsers = false;
    extraSystemCallFilter = [ "@chown" ];
  };

  # bpf: authentik-ldap (Go binary) probes for eBPF at startup
  systemd.services.authentik-ldap.serviceConfig = mkHardened {
    extraSystemCallFilter = [
      "@chown"
      "bpf"
    ];
  };

  homelab.endpoints.authentik = {
    ip = authentikIp;
    port = authentikHttpsPort;
    tls = true;
  };

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/private/authentik";
      mode = "0700";
    }
    {
      directory = "/var/lib/postgresql";
      user = "postgres";
      group = "postgres";
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
