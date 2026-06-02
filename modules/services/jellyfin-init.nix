{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.services.jellyfin-init;
  baseUrl = "http://127.0.0.1:${toString cfg.port}";
in
{
  options.services.jellyfin-init = {
    enable = lib.mkEnableOption "Jellyfin one-time setup wizard completion";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8096;
    };

    adminUser = lib.mkOption {
      type = lib.types.str;
      default = "admin";
    };

    adminPasswordFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to file containing the initial admin password (e.g. a sops secret).";
    };

    serverName = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.jellyfin-init = {
      description = "Jellyfin one-time setup wizard";
      after = [ "jellyfin.service" ];
      requires = [ "jellyfin.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      path = [
        pkgs.curl
        pkgs.jq
        pkgs.coreutils
      ];

      script = ''
        url="${baseUrl}"

        echo "jellyfin-init: waiting for Jellyfin to be ready..."
        for i in {1..60}; do
          if curl -sf "$url/System/Info/Public" > /dev/null 2>&1; then
            if curl -sf "$url/Startup/User" > /dev/null 2>&1 || [ "$(curl -s -o /dev/null -w "%{http_code}" "$url/Startup/User")" = "401" ]; then
              echo "jellyfin-init: Jellyfin is ready."
              break
            fi
          fi
          echo "jellyfin-init: waiting... ($i/60)"
          sleep 5
        done

        completed=$(curl -sf "$url/System/Info/Public" | jq -r '.StartupWizardCompleted')
        if [ "$completed" = "true" ]; then
          echo "jellyfin-init: wizard already completed, nothing to do."
          exit 0
        fi

        password=$(cat "${cfg.adminPasswordFile}")

        echo "jellyfin-init: setting initial configuration..."
        curl -sf -X POST "$url/Startup/Configuration" \
          -H "Content-Type: application/json" \
          -d "$(jq -n \
                --arg name "${cfg.serverName}" \
                '{ServerName: $name, UICulture: "en-US", MetadataCountryCode: "US", PreferredMetadataLanguage: "en"}')"

        echo "jellyfin-init: initializing user creation..."
        curl -sf -X GET "$url/Startup/User" > /dev/null

        echo "jellyfin-init: creating admin user..."
        curl -sf -X POST "$url/Startup/User" \
          -H "Content-Type: application/json" \
          -d "$(jq -n \
                --arg name "${cfg.adminUser}" \
                --arg pass "$password" \
                '{Name: $name, Password: $pass, ConfirmPassword: $pass}')"

        echo "jellyfin-init: configuring remote access..."
        curl -sf -X POST "$url/Startup/RemoteAccess" \
          -H "Content-Type: application/json" \
          -d '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}'

        echo "jellyfin-init: completing wizard..."
        curl -sf -X POST "$url/Startup/Complete"

        echo "jellyfin-init: wizard completed successfully."
      '';
    };
  };
}
