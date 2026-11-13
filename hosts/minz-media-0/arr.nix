{
  config,
  lib,
  pkgs,
  node,
  topology,
  mkHardened,
  ...
}:

let
  mediaIp = node.networks.incus_bridge.ip;
  lp = topology.contracts.localPorts.minz-media-0;
  arrHost = topology.contracts.publicHosts.arr;
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
  services.seerr.stateRevision = 1;
  systemd.services.seerr.environment.NODE_EXTRA_CA_CERTS = "/etc/ssl/certs/ca-bundle.crt";

  users.users.sonarr.extraGroups = [ "media" ];
  users.users.radarr.extraGroups = [ "media" ];
  users.users.bazarr.extraGroups = [ "media" ];

  services.sonarr = {
    enable = true;
    settings.server.port = lp.sonarr.port;
    settings.server.urlBase = lp.sonarr.urlBase;
    settings.server.allowedHosts = "${arrHost},${mediaIp},host.containers.internal";
    environmentFiles = [ config.sops.templates.sonarr-env.path ];
  };
  systemd.services.sonarr.serviceConfig.UMask = lib.mkForce "0002";

  services.radarr = {
    enable = true;
    settings.server.port = lp.radarr.port;
    settings.server.urlBase = lp.radarr.urlBase;
    settings.server.allowedHosts = "${arrHost},${mediaIp},host.containers.internal";
    environmentFiles = [ config.sops.templates.radarr-env.path ];
  };
  systemd.services.radarr.serviceConfig.UMask = lib.mkForce "0002";

  services.prowlarr = {
    enable = true;
    settings.server.port = lp.prowlarr.port;
    settings.server.urlBase = lp.prowlarr.urlBase;
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

  sops.secrets.bazarr_api_key.sopsFile = ../../secrets/shared/bazarr-api.yaml;
  sops.secrets.opensubtitlescom_username.sopsFile = ../../secrets/shared/bazarr.yaml;
  sops.secrets.opensubtitlescom_password.sopsFile = ../../secrets/shared/bazarr.yaml;
  sops.secrets.subdl_api_key.sopsFile = ../../secrets/shared/bazarr.yaml;
  sops.secrets.subsource_api_key.sopsFile = ../../secrets/shared/bazarr.yaml;
  sops.secrets.anidb_api_client.sopsFile = ../../secrets/shared/bazarr.yaml;

  sops.templates.bazarr-env = {
    restartUnits = [ "bazarr.service" ];
    content =
      let
        ph = config.sops.placeholder;
      in
      ''
        DYNACONF_AUTH__APIKEY='@str ${ph.bazarr_api_key}'
        DYNACONF_SONARR__APIKEY='@str ${ph.sonarr_api_key}'
        DYNACONF_RADARR__APIKEY='@str ${ph.radarr_api_key}'
        DYNACONF_OPENSUBTITLESCOM__USERNAME='@str ${ph.opensubtitlescom_username}'
        DYNACONF_OPENSUBTITLESCOM__PASSWORD='@str ${ph.opensubtitlescom_password}'
        DYNACONF_SUBDL__API_KEY='@str ${ph.subdl_api_key}'
        DYNACONF_SUBSOURCE__APIKEY='@str ${ph.subsource_api_key}'
        DYNACONF_ANIDB__API_CLIENT='@str ${ph.anidb_api_client}'
      '';
  };
  sops.templates.bazarr-api-header = {
    restartUnits = [ "bazarr-languages.service" ];
    content = "X-API-KEY: ${config.sops.placeholder.bazarr_api_key}";
  };

  services.bazarr = {
    enable = true;
    package = pkgs.bazarr.overrideAttrs (
      finalAttrs: old: {
        version = "1.6.3-beta.30";
        src = pkgs.fetchFromGitHub {
          owner = "morpheus65535";
          repo = "bazarr";
          tag = "v${finalAttrs.version}";
          hash = "sha256-koqBDkRehh4Ttj2NkykSI7b+/w7C3IK9UnHzgxADqgI=";
        };
        passthru = old.passthru // {
          frontend = old.passthru.frontend.overrideAttrs (
            _: oldFrontend: {
              inherit (finalAttrs) src version;
              npmDeps = oldFrontend.npmDeps.overrideAttrs {
                outputHash = "sha256-inCqUS7G7AJecguKyh77x9B1cMQsLfVIQELOj36kDCY=";
              };
            }
          );
        };
      }
    );
    settings = {
      general = {
        ip = "127.0.0.1";
        base_url = "/bazarr";
        use_sonarr = true;
        use_radarr = true;
        enabled_providers = [
          "animetosho_net"
          "opensubtitlescom"
          "subdl"
          "subsource"
          "subvault"
        ];
        serie_default_enabled = true;
        serie_default_profile = 1;
        movie_default_enabled = true;
        movie_default_profile = 1;
        use_embedded_subs = true;
        ignore_pgs_subs = true;
        ignore_vobsub_subs = true;
        ignore_ass_subs = false;
        adaptive_searching = true;
        upgrade_subs = true;
        minimum_score = 85;
        minimum_score_movie = 75;
      };
      sonarr = {
        ip = "127.0.0.1";
        inherit (lp.sonarr) port;
        base_url = lp.sonarr.urlBase;
        ssl = false;
      };
      radarr = {
        ip = "127.0.0.1";
        inherit (lp.radarr) port;
        base_url = lp.radarr.urlBase;
        ssl = false;
      };
      subsync.use_subsync = false;
      opensubtitlescom.use_hash = true;
      anidb.api_client_ver = 1;
    };
  };

  systemd.services.bazarr = {
    environment.TZ = "UTC";
    serviceConfig.EnvironmentFile = config.sops.templates.bazarr-env.path;
    preStart = "rm -f /var/lib/bazarr/config/config.yaml";
  };

  systemd.services.bazarr-languages = {
    description = "Apply Bazarr language profiles";
    after = [ "bazarr.service" ];
    requires = [ "bazarr.service" ];
    wantedBy = [ "bazarr.service" ];
    partOf = [ "bazarr.service" ];
    path = [ pkgs.curl ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script =
      let
        profiles = builtins.toJSON [
          {
            profileId = 1;
            name = "English";
            profileType = "basic";
            cutoff = null;
            items = [
              {
                id = 1;
                language = "en";
                forced = "False";
                hi = "False";
                audio_exclude = "False";
                audio_only_include = "False";
              }
            ];
            mustContain = [ ];
            mustNotContain = [ ];
            originalFormat = null;
            tag = null;
          }
          {
            profileId = 2;
            name = "English + Japanese";
            profileType = "basic";
            cutoff = null;
            items =
              lib.imap1
                (id: language: {
                  inherit id language;
                  forced = "False";
                  hi = "False";
                  audio_exclude = "False";
                  audio_only_include = "False";
                })
                [
                  "en"
                  "ja"
                ];
            mustContain = [ ];
            mustNotContain = [ ];
            originalFormat = null;
            tag = null;
          }
        ];
      in
      ''
        curl -fsS --retry 30 --retry-all-errors --retry-delay 2 -o /dev/null \
          -H @${config.sops.templates.bazarr-api-header.path} \
          --data-urlencode languages-enabled=en \
          --data-urlencode languages-enabled=ja \
          --data-urlencode languages-profiles=${lib.escapeShellArg profiles} \
          http://127.0.0.1:6767/bazarr/api/system/settings
      '';
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
