{
  config,
  lib,
  pkgs,
  node,
  mkHardened,
  ...
}:

let
  mediaIp = node.networks.incus_bridge.ip;
in
{
  sops.secrets.sonarr_api_key.sopsFile = ../../secrets/shared/arr.yaml;
  sops.secrets.radarr_api_key.sopsFile = ../../secrets/shared/arr.yaml;
  sops.secrets.prowlarr_api_key.sopsFile = ../../secrets/shared/prowlarr.yaml;

  sops.templates.sonarr-env = {
    restartUnits = [
      "sonarr.service"
    ];
    content = "SONARR__AUTH__APIKEY=${config.sops.placeholder.sonarr_api_key}";
    owner = "sonarr";
  };
  sops.templates.radarr-env = {
    restartUnits = [
      "radarr.service"
    ];
    content = "RADARR__AUTH__APIKEY=${config.sops.placeholder.radarr_api_key}";
    owner = "radarr";
  };
  # root:root 0400: EnvironmentFile is read as root before DynamicUser UID is allocated
  sops.templates.prowlarr-env = {
    restartUnits = [
      "prowlarr.service"
    ];
    content = "PROWLARR__AUTH__APIKEY=${config.sops.placeholder.prowlarr_api_key}";
  };

  sops.templates.recyclarr-env = {
    content = ''
      SONARR_API_KEY=${config.sops.placeholder.sonarr_api_key}
      RADARR_API_KEY=${config.sops.placeholder.radarr_api_key}
    '';
    owner = "recyclarr";
  };

  services.seerr.enable = true;
  systemd.services.seerr.environment.NODE_EXTRA_CA_CERTS = "/etc/ssl/certs/ca-bundle.crt";

  users.users.sonarr.extraGroups = [ "media" ];
  users.users.radarr.extraGroups = [ "media" ];
  users.users.bazarr.extraGroups = [ "media" ];

  services.sonarr = {
    enable = true;
    settings.server.urlBase = "/sonarr";
    settings.server.allowedHosts = "arr.minz1.com,${mediaIp},host.containers.internal";
    environmentFiles = [ config.sops.templates.sonarr-env.path ];
  };
  systemd.services.sonarr.serviceConfig.UMask = lib.mkForce "0002";

  services.radarr = {
    enable = true;
    settings.server.urlBase = "/radarr";
    settings.server.allowedHosts = "arr.minz1.com,${mediaIp},host.containers.internal";
    environmentFiles = [ config.sops.templates.radarr-env.path ];
  };
  systemd.services.radarr.serviceConfig.UMask = lib.mkForce "0002";

  services.prowlarr = {
    enable = true;
    settings.server.urlBase = "/prowlarr";
    environmentFiles = [ config.sops.templates.prowlarr-env.path ];
  };
  systemd.services.prowlarr.serviceConfig =
    (mkHardened {
      umask = null;
      extraSystemCallFilter = [ "@chown" ];
    })
    // {
      # no + prefix: runs as DynamicUser so Definitions/ is created with correct ownership
      ExecStartPre = pkgs.writeShellScript "prowlarr-setup-definitions" ''
        mkdir -p /var/lib/prowlarr/Definitions
        ln -sfT ${../../config/prowlarr/indexers} /var/lib/prowlarr/Definitions/Custom
      '';
    };

  services.bazarr.enable = true;

  systemd.services.bazarr = {
    environment.TZ = "UTC";
  };

  services.recyclarr.enable = true;

  systemd.services.recyclarr.serviceConfig = {
    ExecStartPre =
      let
        settings = (pkgs.formats.yaml { }).generate "recyclarr-settings.yml" {
          resource_providers = [
            {
              name = "local-sonarr";
              type = "custom-formats";
              path = "${../../config/recyclarr/custom-formats/sonarr}";
              service = "sonarr";
            }
          ];
        };
      in
      "${pkgs.coreutils}/bin/ln -sfT ${settings} /var/lib/recyclarr/settings.yml";
    ExecStart = lib.mkForce "${config.services.recyclarr.package}/bin/recyclarr sync --config ${../../config/recyclarr/recyclarr.yml}";
    EnvironmentFile = config.sops.templates.recyclarr-env.path;
  };
}
