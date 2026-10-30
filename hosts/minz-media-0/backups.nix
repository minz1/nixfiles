{
  ...
}:

let
  mediaBackupUnits = "sonarr.service radarr.service prowlarr.service bazarr.service seerr.service jellyfin.service";
in
{
  # Config + operational state only — not the media library itself (lives on NFS/decypharr mounts
  # elsewhere) and not decypharr's disposable cache (docs/ops.md). Deliberately excludes zilean's
  # postgres: it's a DMM/IMDb scrape cache the service rebuilds on its own, not user data.
  # The apps keep live SQLite DBs in WAL mode, so they're stopped for the ~30s snapshot; decypharr
  # stays up since it backs the streaming mounts, and its small DB is the one hot copy. Its usenet metadata is
  # its own target so the arrs' stop window doesn't grow with it.
  homelab.backups.targets.media-configs = {
    paths = [
      "/var/lib/sonarr"
      "/var/lib/radarr"
      "/var/lib/private/prowlarr"
      "/var/lib/private/jellyseerr"
      "/var/lib/bazarr"
      "/var/lib/jellyfin"
      "/var/lib/decypharr/db"
    ];
    prepareCommand = "systemctl stop ${mediaBackupUnits}";
    cleanupCommand = "systemctl start ${mediaBackupUnits}";
    timerConfig = {
      OnCalendar = "*-*-* 06:00:00 America/New_York";
      RandomizedDelaySec = "30m";
      Persistent = true;
    };
  };
  homelab.backups.targets.decypharr-usenet = {
    paths = [
      "/var/lib/decypharr/usenet/meta"
      "/var/lib/decypharr/usenet/nzbs"
    ];
    timerConfig = {
      OnCalendar = "*-*-* 05:30:00";
      RandomizedDelaySec = "30m";
      Persistent = true;
    };
  };
}
