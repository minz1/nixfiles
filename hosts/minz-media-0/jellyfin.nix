{
  config,
  pkgs,
  ...
}:

{
  sops.secrets.jellyfin_admin_password = { };

  # Arc A310 DRM passthrough via Incus cgroup allowlist; VAAPI device: /dev/dri/renderD129
  hardware.graphics.enable = true;
  hardware.graphics.extraPackages = with pkgs; [
    intel-media-driver
    intel-compute-runtime
    vpl-gpu-rt # Required for Intel Arc (DG2) QuickSync support
  ];

  # one-time setup wizard completion, so a fresh volume comes up usable without clicking through the UI
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
      url="http://127.0.0.1:8096"

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

      password=$(cat "${config.sops.secrets.jellyfin_admin_password.path}")

      echo "jellyfin-init: setting initial configuration..."
      curl -sf -X POST "$url/Startup/Configuration" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
              --arg name "${config.networking.hostName}" \
              '{ServerName: $name, UICulture: "en-US", MetadataCountryCode: "US", PreferredMetadataLanguage: "en"}')"

      echo "jellyfin-init: initializing user creation..."
      curl -sf -X GET "$url/Startup/User" > /dev/null

      echo "jellyfin-init: creating admin user..."
      curl -sf -X POST "$url/Startup/User" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
              --arg name "admin" \
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

  # jellyfin needs render+video group membership to access /dev/dri/renderD128 in the container.
  users.users.jellyfin.extraGroups = [
    "render"
    "video"
  ];

  services.jellyfin = {
    enable = true;
    hardwareAcceleration = {
      enable = true;
      type = "qsv";
      device = "/dev/dri/renderD129";
    };
    forceEncodingConfig = true;
    transcoding = {
      enableHardwareEncoding = true;
      throttleTranscoding = true;
      enableToneMapping = true;
      hardwareDecodingCodecs = {
        h264 = true;
        hevc = true;
        hevc10bit = true;
        vp9 = true;
        av1 = true;
        mpeg2 = true;
        vc1 = true;
      };
      hardwareEncodingCodecs = {
        hevc = true;
        av1 = true;
      };
    };
  };
}
