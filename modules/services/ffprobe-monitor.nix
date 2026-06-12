{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.ffprobe-monitor;
in
{
  options.services.ffprobe-monitor = {
    enable = lib.mkEnableOption "FFprobe stuck-process monitor";

    package = lib.mkOption {
      type = lib.types.package;
      defaultText = "pkgs.ffprobe-monitor (built with module options)";
      description = "ffprobe-monitor package to use.";
    };

    intervalSec = lib.mkOption {
      type = lib.types.int;
      default = 30;
      description = "Sleep time between monitoring cycles.";
    };

    minProcessAgeSec = lib.mkOption {
      type = lib.types.int;
      default = 30;
      description = "Minimum process age in seconds before we consider poking.";
    };

    minPokeIntervalSec = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = "Minimum interval between pokes for the same file.";
    };

    pokeTimeoutSec = lib.mkOption {
      type = lib.types.int;
      default = 10;
      description = "Timeout for the ffprobe poke subprocess.";
    };

    maxPokesPerCycle = lib.mkOption {
      type = lib.types.int;
      default = 3;
      description = "Maximum number of pokes per monitoring cycle.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.ffprobe-monitor.package = lib.mkDefault (pkgs.ffprobe-monitor.override {
      inherit (cfg) intervalSec minPokeIntervalSec pokeTimeoutSec;
      minAgeSec = cfg.minProcessAgeSec;
      maxStuckPerFile = cfg.maxPokesPerCycle;
    });

    environment.systemPackages = [ cfg.package ];

    systemd.services.ffprobe-monitor = {
      description = "Monitor and poke stuck ffprobe processes";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/ffprobe-monitor";
        Restart = "always";
        RestartSec = "10s";
        # Lowest IO / CPU priority so it never interferes with media serving
        IOSchedulingClass = "idle";
        CPUSchedulingPolicy = "idle";
        Nice = 19;
      };
    };
  };
}
