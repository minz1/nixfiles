{
  config,
  lib,
  hostEndpoints,
  mkHardened,
  ...
}:

let
  victoriaPort = 9090;
  lokiPort = 3100;
  grafanaPort = 3000;
  certDir = "/var/lib/acme/minz-obs-0.internal";
  authentikHttpsPort = hostEndpoints.minz-authentik-0.authentik.port;
in
{
  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_port = grafanaPort;
        domain = "grafana.minz1.com";
        root_url = "https://grafana.minz1.com/";
      };
      security = {
        # $__file{} is expanded by Grafana's file provider at runtime.
        admin_password = "$__file{${config.sops.secrets.grafana_admin_password.path}}";
        secret_key = "$__file{${config.sops.secrets.grafana_secret_key.path}}";
        cookie_secure = true;
      };
      analytics = {
        reporting_enabled = false;
        check_for_updates = false;
      };
      live = {
        allowed_origins = "https://grafana.minz1.com";
      };
      "auth.generic_oauth" = {
        enabled = true;
        name = "Authentik";
        icon = "signin";
        client_id = "grafana";
        client_secret = "$__file{${config.sops.secrets.grafana_oauth_client_secret.path}}";
        scopes = "openid email profile";
        auth_url = "https://auth.minz1.com/application/o/authorize/";
        token_url = "https://minz-authentik-0.internal:${toString authentikHttpsPort}/application/o/token/";
        api_url = "https://minz-authentik-0.internal:${toString authentikHttpsPort}/application/o/userinfo/";
        role_attribute_path = "contains(groups[*], 'grafana-admins') && 'Admin' || 'Viewer'";
        allow_sign_up = true;
        tls_client_cert = "${certDir}/cert.pem";
        tls_client_key = "${certDir}/key.pem";
        tls_client_ca = "/etc/ssl/internal-ca.crt";
      };
      "auth" = {
        disable_login_form = true;
      };
      # Resend, same provider/creds pattern as authentik-0 and Seerr.
      smtp = {
        enabled = true;
        host = "smtp.resend.com:587";
        user = "resend";
        # $__file{} is expanded by Grafana's file provider at runtime.
        password = "$__file{${config.sops.secrets.grafana_smtp_password.path}}";
        from_address = "noreply@minz1.com";
      };
    };
    provision = {
      enable = true;
      # uid pinned for alert rules; deleteDatasources avoids the update-path crash
      datasources.settings = {
        deleteDatasources = [
          {
            name = "VictoriaMetrics";
            orgId = 1;
          }
          {
            name = "Loki";
            orgId = 1;
          }
        ];
        datasources = [
          {
            name = "VictoriaMetrics";
            uid = "victoriametrics";
            type = "prometheus";
            url = "http://127.0.0.1:${toString victoriaPort}";
            isDefault = true;
          }
          {
            name = "Loki";
            uid = "loki";
            type = "loki";
            url = "http://127.0.0.1:${toString lokiPort}";
          }
        ];
      };
    };
  };

  # ntfy_grafana_password: plaintext, sent over HTTP Basic Auth; distinct from ntfy_grafana_password_hash on services-0, same source password
  sops.secrets =
    lib.genAttrs
      [
        "grafana_smtp_password"
        "ntfy_grafana_password"
        "grafana_admin_password"
        "grafana_secret_key"
        "grafana_oauth_client_secret"
      ]
      (_: {
        owner = "grafana";
      });

  sops.templates."grafana-alerting-env" = {
    content = "NTFY_PASSWORD=${config.sops.placeholder.ntfy_grafana_password}";
    owner = "grafana";
  };

  users.users.grafana.extraGroups = [ "caddy" ];

  systemd.services.grafana.serviceConfig = mkHardened { } // {
    EnvironmentFile = config.sops.templates."grafana-alerting-env".path;
  };
  # environmentFile content changes don't restart the service on their own
  systemd.services.grafana.restartTriggers = [
    config.sops.templates."grafana-alerting-env".content
  ];
}
