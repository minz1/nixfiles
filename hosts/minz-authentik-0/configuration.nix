{
  hostName,
  config,
  pkgs,
  lib,
  authentik-nix,
  ...
}:

let
  topology = import ../../common/topology.nix;
  node = topology.nodes."${hostName}";
  authentikPort = node.services.authentik.port;
  authentikHttpsPort = node.services.authentik.httpsPort;
  ldapPort = node.services.ldap.port;
  ldapTlsPort = node.services.ldap.tlsPort;
  authentikIp = node.networks.incus_bridge.ip;
  # Caddy owns authentikHttpsPort and ldapTlsPort externally; push the outpost listeners
  # one port higher on loopback so there is no conflict.
  authentikBuiltinHttpsPort = authentikHttpsPort + 1;
  ldapOutpostTlsPort = ldapTlsPort + 1;
  acmeHttpPort = 80;
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
      plugins = [ "github.com/mholt/caddy-l4@v0.1.1" ];
      hash = "sha256-CQ4vKkQ9sE6v5C0gcyYPBnDzJiPw5z14a3lY0BLZ81A=";
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
              automatic_https.disable_redirects = true;
              tls_connection_policies = [
                { certificate_selection.any_tag = [ "authentik" ]; }
              ];
              routes = [
                {
                  handle = [
                    {
                      handler = "reverse_proxy";
                      upstreams = [ { dial = "localhost:${toString authentikPort}"; } ];
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

  security.acme = {
    acceptTerms = true;
    defaults = {
      server = "https://minz-pki-0.internal:9443/acme/acme/directory";
      email = "emerytang@gmail.com";
    };
    certs."minz-authentik-0.internal" = {
      listenHTTP = ":${toString acmeHttpPort}";
      reloadServices = [ "caddy.service" ];
      group = "caddy";
      extraDomainNames = [ authentikIp ];
    };
  };

  networking.firewall.allowedTCPPorts = [
    authentikHttpsPort
    ldapTlsPort
    acmeHttpPort
  ];

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
