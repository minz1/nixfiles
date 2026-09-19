{
  config,
  pkgs,
  lib,
  authentik-nix,
  node,
  topology,
  mkHardened,
  ...
}:

let
  authentikIp = node.networks.incus_bridge.ip;

  authentikPort = 9000;
  desktopIp = topology.nodes."minz-desktop".networks.mgmt.ip;
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

  system.stateVersion = "25.11";

  sops.secrets.authentik_env = { };
  sops.secrets.authentik_ldap_token = { };

  sops.templates.authentik-ldap-env = {
    content = ''
      AUTHENTIK_HOST=http://localhost:${toString authentikPort}
      AUTHENTIK_INSECURE=false
      AUTHENTIK_TOKEN=${config.sops.placeholder.authentik_ldap_token}
      AUTHENTIK_LISTEN__LDAPS=127.0.0.1:${toString ldapOutpostTlsPort}
    '';
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
              strict_sni_host = false;
              # the edge Caddy sets X-Forwarded-For from the real peer; without this every public client is the edge's IP
              trusted_proxies = {
                source = "static";
                ranges = [ "${topology.nodes."minz-vultr-nix-1".networks.edge.ip}/32" ];
              };
              tls_connection_policies = [
                {
                  # the desktop only: Tofu's authentik provider can't present a client cert. The rest of
                  # the mgmt subnet (both Vultr hosts, unmanaged devices) goes through mTLS like everyone else.
                  match.remote_ip.ranges = [ "${desktopIp}/32" ];
                  certificate_selection.any_tag = [ "authentik" ];
                }
                {
                  certificate_selection.any_tag = [ "authentik" ];
                  client_authentication = {
                    trusted_ca_certs_pem_files = [ "/etc/ssl/internal-ca.crt" ];
                    mode = "require_and_verify";
                  };
                }
              ];
              routes = [
                {
                  match = [
                    {
                      not = [
                        {
                          expression = ''{http.request.tls.client.subject} == "CN=minz-vultr-nix-1.internal" || {http.request.tls.client.subject} == "CN=minz-obs-0.internal" || {http.request.tls.client.subject} == "CN=minz-game-0.internal"'';
                        }
                        {
                          remote_ip.ranges = [ "${desktopIp}/32" ];
                        }
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
                  # preserve X-Forwarded-Host from edge Caddy when present; overwriting it
                  # breaks outpost proxy provider matching. Only applies when the caller
                  # actually set one — see below for direct/server-to-server callers.
                  match = [ { header.X-Forwarded-Host = [ "*" ]; } ];
                  handle = [
                    {
                      handler = "reverse_proxy";
                      upstreams = [ { dial = "localhost:${toString authentikPort}"; } ];
                      headers.request.set."X-Forwarded-Host" = [ "{http.request.header.X-Forwarded-Host}" ];
                    }
                  ];
                }
                {
                  # direct/server-to-server callers (Grafana's OIDC token exchange, mTLS
                  # clients) send no X-Forwarded-Host at all; don't force it to empty
                  # here — Caddy's own reverse_proxy default (the real incoming Host)
                  # is correct, and forcing empty makes Authentik 404 the request.
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

  networking.firewall.allowedTCPPorts = [
    authentikHttpsPort
    ldapTlsPort
  ];

  # authentik's own cert-discovery watcher (unrelated to our step-ca certs) defaults to
  # /certs, a Docker-image convention; missing here, it throws a "critical"-level
  # FileNotFoundError in authentik-worker on every boot. Create the empty dir so it starts.
  systemd.tmpfiles.rules = [ "d /certs 0755 root root -" ];

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
  };

  # setpriv privilege drop for pg_dumpall; see docs/main-plan.md's S6 section for why.
  homelab.backups.targets.authentik-db = {
    paths = [ "/var/backup/authentik-db.sql" ];
    prepareCommand = ''
      mkdir -p /var/backup
      ${pkgs.util-linux}/bin/setpriv --reuid postgres --regid postgres --init-groups -- ${config.services.postgresql.package}/bin/pg_dumpall --clean --if-exists > /var/backup/authentik-db.sql
    '';
    extraCapabilities = [
      "CAP_SETUID"
      "CAP_SETGID"
    ];
    extraSystemCallFilter = [
      "setuid"
      "setgid"
      "setresuid"
      "setresgid"
      "setreuid"
      "setregid"
      "setgroups"
      "setfsuid"
      "setfsgid"
      "capset"
    ];
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
  ];
}
