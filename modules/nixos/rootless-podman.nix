{ config, lib, ... }:

with lib;

let
  cfg = config.services.rootless-podman;
in
{
  options.services.rootless-podman = {
    enable = mkEnableOption "rootless podman service account";

    user = mkOption {
      type = types.str;
      description = "Username for the rootless podman service account.";
    };

    uid = mkOption {
      type = types.int;
      description = "UID for the rootless podman service account.";
    };
  };

  config = mkIf cfg.enable {
    users.manageLingering = true;

    users.users.${cfg.user} = {
      isSystemUser = true;
      inherit (cfg) uid;
      group = cfg.user;
      home = "/var/lib/${cfg.user}";
      createHome = true;
      linger = true;
      subUidRanges = [
        {
          startUid = 100000;
          count = 65536;
        }
      ];
      subGidRanges = [
        {
          startGid = 100000;
          count = 65536;
        }
      ];
    };
    users.groups.${cfg.user} = { };

    # no autoPrune: it prunes root's store, which a rootless-only host never uses. The podman module
    # still emits podman-prune.timer with no OnCalendar, which systemd rejects on switch — drop the unit.
    virtualisation.podman = {
      enable = true;
      defaultNetwork.settings.dns_enabled = true;
    };
    systemd.timers.podman-prune.enable = false;
  };
}
