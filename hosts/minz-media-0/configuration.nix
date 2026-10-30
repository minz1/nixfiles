{
  lib,
  ...
}:

{
  imports = [
    ../../modules/nixos/rootless-podman.nix
    ./arr.nix
    ./backups.nix
    ./caddy.nix
    ./containers.nix
    ./decypharr.nix
    ./jellyfin.nix
  ];

  system.stateVersion = "25.11";

  # lxc-container.nix disables programs.fuse, stripping the setuid fusermount3 wrapper rclone needs for non-root FUSE mounts — re-enable it explicitly.
  programs.fuse.enable = lib.mkForce true;

  services.rootless-podman = {
    enable = true;
    user = "oci";
    uid = 902;
  };

  users.groups.media = { };

  systemd.tmpfiles.rules = [
    "d /mnt/decypharr               0775 root   media  -"
    "d /var/lib/zilean               0700 oci    oci    -"
    "d /var/lib/comet                0700 oci    oci    -"
    "d /data                         0755 root   root   -"
    "d /data/downloads/sonarr        2775 sonarr media  -"
    "d /data/downloads/radarr        2775 radarr media  -"
    "d /data/library                 0775 root   media  -"
    "d /data/library/tv              2775 sonarr media  -"
    "d /data/library/anime           2775 sonarr media  -"
    "d /data/library/movies          2775 radarr media  -"
  ];
}
