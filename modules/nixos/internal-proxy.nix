{
  lib,
  config,
  hostName,
  topology,
  ...
}:

let
  inherit (lib) mkOption types;
  cfg = config.homelab.internalProxy;
  inherit (import ../lib/caddy.nix { inherit lib topology; }) denyUnless;
  tag = [ "internal-proxy" ];

  policies =
    s:
    lib.optional (s.clientAuth == "require" && s.allowedSources != [ ]) {
      match.remote_ip.ranges = s.allowedSources;
      certificate_selection.any_tag = tag;
    }
    ++ [
      (
        {
          certificate_selection.any_tag = tag;
        }
        // lib.optionalAttrs (s.clientAuth != "none") {
          client_authentication = {
            trusted_ca_certs_pem_files = [ "/etc/ssl/internal-ca.crt" ];
            mode = if s.clientAuth == "require" then "require_and_verify" else "verify_if_given";
          };
        }
        // lib.optionalAttrs (s.handshakeSources != [ ]) {
          match.remote_ip.ranges = s.handshakeSources;
        }
      )
    ];

  routes =
    s:
    lib.optional (s.allowedClientNodes != [ ] || s.allowedSources != [ ]) (denyUnless {
      nodes = s.allowedClientNodes;
      sources = s.allowedSources;
    })
    ++ s.routes
    ++ lib.optional (s.upstream != null) {
      handle = [
        {
          handler = "reverse_proxy";
          upstreams = [ { dial = "127.0.0.1:${toString s.upstream}"; } ];
          headers.request.set."Host" = [ "{http.request.host}" ];
        }
      ];
    };

  rendered = config.services.caddy.settings.apps.http.servers;
in
{
  options.homelab.internalProxy.servers = mkOption {
    default = { };
    description = "Caddy servers fronting loopback backends with the host's step-ca cert and optional mTLS.";
    type = types.attrsOf (
      types.submodule {
        options = {
          port = mkOption { type = types.port; };
          address = mkOption {
            type = types.str;
            default = "";
          };
          clientAuth = mkOption {
            type = types.enum [
              "none"
              "verify_if_given"
              "require"
            ];
            default = "none";
          };
          allowedClientNodes = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "Fleet nodes whose client cert (CN=<node>.internal) passes the guard.";
          };
          allowedSources = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "CIDRs that pass the guard without a client cert.";
          };
          handshakeSources = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "If set, TLS only completes for these CIDRs.";
          };
          routes = mkOption {
            type = types.listOf types.attrs;
            default = [ ];
            description = "Raw Caddy routes after the guard, before the upstream route.";
          };
          upstream = mkOption {
            type = types.nullOr types.port;
            default = null;
            description = "Loopback port for the final catch-all reverse_proxy route.";
          };
        };
      }
    );
  };

  config = lib.mkIf (cfg.servers != { }) {
    services.caddy = {
      enable = true;
      settings.apps = {
        tls.certificates.load_files = [
          {
            certificate = "/var/lib/acme/${hostName}.internal/cert.pem";
            key = "/var/lib/acme/${hostName}.internal/key.pem";
            tags = tag;
          }
        ];
        http.servers = lib.mapAttrs (_: s: {
          listen = [ "${s.address}:${toString s.port}" ];
          automatic_https.disable = true;
          strict_sni_host = false;
          tls_connection_policies = policies s;
          routes = routes s;
        }) cfg.servers;
      };
    };

    assertions = lib.concatLists (
      lib.mapAttrsToList (n: s: [
        {
          assertion = s.allowedClientNodes == [ ] || s.clientAuth != "none";
          message = "internalProxy.${n}: allowedClientNodes needs clientAuth other than none";
        }
        {
          assertion = s.clientAuth != "require" || s.allowedClientNodes != [ ] || s.handshakeSources != [ ];
          message = "internalProxy.${n}: require with no allowedClientNodes admits every fleet cert; set handshakeSources";
        }
        {
          assertion = rendered.${n}.routes == routes s && rendered.${n}.tls_connection_policies == policies s;
          message = "internalProxy.${n}: routes or tls_connection_policies were also set outside the module";
        }
      ]) cfg.servers
    );
  };
}
