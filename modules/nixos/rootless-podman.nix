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

    group = mkOption {
      type = types.str;
      description = "Primary group for the rootless podman service account.";
      default = cfg.user;
      defaultText = literalExpression "config.services.rootless-podman.user";
    };
  };

  config = mkIf cfg.enable {
    users.manageLingering = true;

    users.users.${cfg.user} = {
      isSystemUser = true;
      uid = cfg.uid;
      group = cfg.group;
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
    users.groups.${cfg.group} = { };

    virtualisation.podman = {
      enable = true;
      defaultNetwork.settings.dns_enabled = true;
      autoPrune = {
        enable = true;
        dates = "weekly";
      };
    };
  };
}
