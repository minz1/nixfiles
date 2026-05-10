{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.services.decypharr;
in
{
  options.services.decypharr = {
    enable = lib.mkEnableOption "Decypharr debrid mock qBittorrent service";

    mediaGroup = lib.mkOption {
      type = lib.types.str;
      default = "media";
      description = "Unix group name that has access to the media path.";
    };

    mediaPath = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/media";
      description = "Path to the media directory that decypharr can read/write.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8282;
      description = "Port on which decypharr listens.";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.fuse.userAllowOther = true;

    users.users.decypharr = {
      isSystemUser = true;
      group = "decypharr";
      extraGroups = [ cfg.mediaGroup ];
    };
    users.groups.decypharr = { };
    users.groups.${cfg.mediaGroup} = { };

    systemd.services.decypharr = {
      description = "Decypharr - Debrid Mock QBittorrent";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart = "${pkgs.decypharr}/bin/decypharr --config /var/lib/decypharr";

        User = "decypharr";
        Group = "decypharr";
        WorkingDirectory = "/var/lib/decypharr";
        Restart = "on-failure";
        RestartSec = 5;

        ReadWritePaths = [ cfg.mediaPath ];
        RequiresMountsFor = [ cfg.mediaPath ];

        CapabilityBoundingSet = [ "CAP_SYS_ADMIN" ];
        AmbientCapabilities = [ "CAP_SYS_ADMIN" ];
        DeviceAllow = [ "/dev/fuse rw" ];
        PrivateDevices = false;

        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        PrivateTmp = true;
        StateDirectory = "decypharr";
      };
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.mediaPath} 0755 ${cfg.mediaGroup} ${cfg.mediaGroup} -"
    ];
  };
}
