{
  config,
  pkgs,
  ...
}:

let
  sonarrPort = 8989;
  radarrPort = 7878;
in
{
  sops.secrets.zilean_db_password = { };

  # Quadlet EnvironmentFile read by Podman before exec; owner must match the rootless UID
  sops.templates.zilean-postgres-env = {
    restartUnits = [
      "zilean-postgres.service"
    ];
    content = "POSTGRES_PASSWORD=${config.sops.placeholder.zilean_db_password}";
    owner = "oci";
  };
  sops.templates.zilean-app-env = {
    restartUnits = [
      "zilean-app.service"
    ];
    content = ''
      POSTGRES_PASSWORD=${config.sops.placeholder.zilean_db_password}
      Zilean__Database__ConnectionString=Host=localhost;Database=zilean;Username=zilean;Password=${config.sops.placeholder.zilean_db_password};Include Error Detail=true;Timeout=30;CommandTimeout=3600;
    '';
    owner = "oci";
  };
  sops.templates.seadexerr-env = {
    restartUnits = [ "seadexerr.service" ];
    content = ''
      SONARR_API_KEY=${config.sops.placeholder.sonarr_api_key}
      RADARR_API_KEY=${config.sops.placeholder.radarr_api_key}
    '';
    owner = "oci";
  };

  virtualisation.quadlet =
    let
      inherit (config.virtualisation.quadlet) pods containers volumes;
    in
    {
      pods.zilean = {
        rootlessConfig.uid = 902;
        podConfig.publishPorts = [ "127.0.0.1:8181:8181" ];
        podConfig.shmSize = "256m";
      };

      volumes.zilean-pg = {
        rootlessConfig.uid = 902;
      };

      containers = {
        zilean-postgres = {
          rootlessConfig.uid = 902;
          containerConfig = {
            image = "docker.io/library/postgres:16-alpine@sha256:f4610795587492cd4fb887c2dc3de301b813278bb6f616992061141b5f15ac36";
            pod = pods.zilean.ref;
            volumes = [ "${volumes.zilean-pg.ref}:/var/lib/postgresql/data" ];
            environments = {
              POSTGRES_DB = "zilean";
              POSTGRES_USER = "zilean";
            };
            environmentFiles = [ config.sops.templates.zilean-postgres-env.path ];
          };
        };

        zilean-app = {
          rootlessConfig.uid = 902;
          containerConfig = {
            # No upstream release since 2025-04-21 (project looks dormant); pinned to what's been running rather than following an inactive :latest tag.
            image = "ipromknight/zilean:latest@sha256:1b828ac0604235de7adb7757d11c88c1b3bb1a6319071b0c9d99325bc0f9d477";
            pod = pods.zilean.ref;
            volumes = [ "/var/lib/zilean:/app/data" ];
            # DMM moved hashlists to lists/<id>.txt (2026-09); Zilean can't read them, so serve the existing index only.
            environments.Zilean__Dmm__EnableScraping = "false";
            environmentFiles = [ config.sops.templates.zilean-app-env.path ];
          };
          unitConfig = {
            After = [ containers."zilean-postgres".ref ];
            Requires = [ containers."zilean-postgres".ref ];
          };
        };

        flaresolverr = {
          rootlessConfig.uid = 902;
          containerConfig = {
            image = "ghcr.io/flaresolverr/flaresolverr:latest@sha256:c80ae007ce2ccdcd217a12426e4f039ef763ff90738c808d38810c3e59323767";
            publishPorts = [ "127.0.0.1:8191:8191" ];
            environments.LOG_LEVEL = "info";
          };
        };

        seadexerr = {
          rootlessConfig.uid = 902;
          containerConfig = {
            image = "ghcr.io/ryder-c/seadexerr:v3.2.0@sha256:a4ae04b9eb29120d16a6adaf9520c810cd3d24e2fddcd72209ba24b2971d0483";
            publishPorts = [ "127.0.0.1:6868:2071" ];
            volumes = [
              "${pkgs.writeText "seadexerr-scoring.toml" "dual_audio = 150\n"}:/data/scoring.toml:ro"
            ];
            environments = {
              SONARR_BASE_URL = "http://host.containers.internal:${toString sonarrPort}/sonarr/";
              RADARR_BASE_URL = "http://host.containers.internal:${toString radarrPort}/radarr/";
              SEADEXERR_PUBLIC_BASE_URL = "http://127.0.0.1:6868";
            };
            environmentFiles = [ config.sops.templates.seadexerr-env.path ];
          };
        };

        comet = {
          rootlessConfig.uid = 902;
          containerConfig = {
            image = "ghcr.io/g0ldyy/comet:latest@sha256:dca62133336e02784d02aaad861381820674d1c8e3e98a03797610b81ee4defe";
            publishPorts = [ "127.0.0.1:8000:8000" ];
            # minz1/comet fixes (DMM lists/<id>.txt, animetosho.net) over identical upstream files; drop once upstream merges
            volumes = [
              "/var/lib/comet:/app/data"
              "${
                pkgs.fetchurl {
                  url = "https://raw.githubusercontent.com/minz1/comet/0fdcf6d894f8fa4df08c961b51505cfa5a0ad614/comet/services/dmm_ingester.py";
                  hash = "sha256-FD2whyIsKNatMGhfZfwQVc2cxid/lh8besmflpQ6Oeg=";
                }
              }:/app/comet/services/dmm_ingester.py:ro"
              "${
                pkgs.fetchurl {
                  url = "https://raw.githubusercontent.com/minz1/comet/7bcba210e0858ce2afcd91edb4d84f613a32aaee/comet/scrapers/animetosho.py";
                  hash = "sha256-+PY4NTHAQb9c++ik4z5AltbNhQCL6qj0SVx2kCnqpSI=";
                }
              }:/app/comet/scrapers/animetosho.py:ro"
            ];
            environments = {
              DATABASE_TYPE = "sqlite";
              COMETNET_ENABLED = "False";
              SCRAPE_DMM = "both";
              DMM_INGEST_ENABLED = "True";
              SCRAPE_SEADEX = "both";
              SCRAPE_NYAA = "both";
              SCRAPE_ANIMETOSHO = "both";
            };
          };
        };
      };
    };
}
