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

        # Sandbox is minimal: FUSE mount propagation requires no namespace isolation.
        DeviceAllow = [ "/dev/fuse rw" ];
        PrivateDevices = false;
        UMask = "0002";

        # fusermount3 is setuid-root; NoNewPrivileges/CapabilityBoundingSet break it.
        SystemCallFilter = [
          "@system-service"
          "mount"
          "umount2"
        ];
        RestrictAddressFamilies = "AF_INET AF_INET6 AF_UNIX";
        RestrictNamespaces = true;
        LockPersonality = true;

        # Re-export after FUSE mount so NFS server sees the VFS, not the underlying dir.
        ExecStartPost = "+${pkgs.nfs-utils}/bin/exportfs -ar";
      };
    };

    networking.firewall.allowedTCPPorts = [ cfg.port ];

    systemd.tmpfiles.rules = [
      "d ${cfg.mediaPath} 0775 root ${cfg.mediaGroup} -"
    ];
  };
}
