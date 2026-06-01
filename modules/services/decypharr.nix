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

    downloadPath = lib.mkOption {
      type = lib.types.str;
      default = "/data/downloads";
      description = "Path where decypharr writes category symlinks (must match download_folder in config.json).";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8282;
      description = "Port on which decypharr listens.";
    };
  };

  config = lib.mkIf cfg.enable {
    boot.kernelModules = [ "fuse" ];
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
        StateDirectory = "decypharr";

        # FUSE requires access to /dev/fuse; namespace isolation would prevent
        # mount propagation to the host, so sandbox options are kept minimal here.
        # Non-namespace hardening (NoNewPrivileges, SystemCallFilter, etc.) added in Phase 2.
        DeviceAllow = [ "/dev/fuse rw" ];
        PrivateDevices = false;

        # Re-export NFS shares after the FUSE mount is ready so the kernel NFS server
        # picks up the new mount instead of exporting the underlying directory.
        # Uses '+' to run as root despite the User=decypharr setting.
        ExecStartPost = "+${pkgs.nfs-utils}/bin/exportfs -ar";
      };
    };

    networking.firewall.allowedTCPPorts = [ cfg.port ];

    systemd.tmpfiles.rules = [
      "d ${cfg.mediaPath} 0775 root ${cfg.mediaGroup} -"
    ];
  };
}
