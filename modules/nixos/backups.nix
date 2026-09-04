{
  lib,
  config,
  hostName,
  ...
}:

let
  cfg = config.homelab.backups;
  topology = import ../../common/topology.nix;

  # shared restic repository host for the fleet; rclone mirrors it to B2 separately
  rustfsAddr = topology.nodes."minz-vultr-nix-0".networks.mgmt.ip;
  rustfsPort = 9000;

  mkHardened = import ../lib/hardening.nix { inherit lib; };
in
{
  options.homelab.backups.targets = lib.mkOption {
    default = { };
    description = "restic backup targets for this host, pushed to RustFS over WireGuard.";
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          paths = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "Paths to back up for this target.";
          };
          prepareCommand = lib.mkOption {
            type = lib.types.nullOr lib.types.lines;
            default = null;
            description = "Shell run before the backup.";
          };
          cleanupCommand = lib.mkOption {
            type = lib.types.nullOr lib.types.lines;
            default = null;
            description = "Shell run after the backup.";
          };
          exclude = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
          };
          timerConfig = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = {
              OnCalendar = "daily";
              RandomizedDelaySec = "1h";
              Persistent = true;
            };
          };
          extraCapabilities = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Extra capabilities for this target's restic unit.";
          };
          extraSystemCallFilter = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Extra syscalls for this target's restic unit.";
          };
        };
      }
    );
  };

  config = lib.mkIf (cfg.targets != { }) {
    sops.secrets."restic-password" = { };
    sops.secrets."restic-s3-access-key" = { };
    sops.secrets."restic-s3-secret-key" = { };

    sops.templates."restic-s3-env" = {
      content = ''
        AWS_ACCESS_KEY_ID=${config.sops.placeholder."restic-s3-access-key"}
        AWS_SECRET_ACCESS_KEY=${config.sops.placeholder."restic-s3-secret-key"}
      '';
    };

    services.restic.backups = lib.mapAttrs (name: target: {
      repository = "s3:http://${rustfsAddr}:${toString rustfsPort}/backups/${hostName}/${name}";
      passwordFile = config.sops.secrets."restic-password".path;
      environmentFile = config.sops.templates."restic-s3-env".path;
      inherit (target) paths exclude timerConfig;
      backupPrepareCommand = target.prepareCommand;
      backupCleanupCommand = target.cleanupCommand;
      initialize = true;
      runCheck = true;
      checkOpts = [ "--read-data-subset=5%" ];
      pruneOpts = [
        "--keep-daily 3"
        "--keep-weekly 2"
        "--keep-monthly 3"
        "--keep-yearly 100"
      ];
    }) cfg.targets;

    systemd.services = lib.mapAttrs' (
      name: target:
      lib.nameValuePair "restic-backups-${name}" {
        restartTriggers = [ config.sops.templates."restic-s3-env".content ];
        serviceConfig = mkHardened (
          let
            capabilities = [
              "CAP_DAC_OVERRIDE"
              "CAP_DAC_READ_SEARCH"
            ]
            ++ target.extraCapabilities;
          in
          {
            privateUsers = false;
            capabilityBoundingSet = capabilities;
            ambientCapabilities = capabilities;
            extraSystemCallFilter = target.extraSystemCallFilter;
          }
        );
      }
    ) cfg.targets;
  };
}
