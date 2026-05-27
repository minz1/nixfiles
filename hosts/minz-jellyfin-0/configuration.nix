{
  hostName,
  config,
  pkgs,
  ...
}:

let
  topology = import ../../common/topology.nix;
  node = topology.nodes."${hostName}";
  arrIp = topology.nodes."minz-arr-0".networks.incus_bridge.ip;
  jellyfinPort = node.services.jellyfin.port;
in
{
  imports = [ ../../modules/services/jellyfin-init.nix ];

  networking.hostName = hostName;
  system.stateVersion = "25.11";

  sops.defaultSopsFile = ../../secrets/minz-jellyfin-0.yaml;
  sops.secrets.jellyfin_admin_password.mode = "0400";
  services.jellyfin-init = {
    enable = true;
    adminPasswordFile = config.sops.secrets.jellyfin_admin_password.path;
  };

  # Intel Arc A310 DRM passthrough — cgroup device allowlisting via Incus (no VFIO needed).
  # VAAPI hardware transcoding: Dashboard → Playback → Transcoding → VA-API Device: /dev/dri/renderD128
  hardware.graphics.enable = true;
  hardware.graphics.extraPackages = with pkgs; [
    intel-media-driver
    intel-compute-runtime
  ];

  # jellyfin needs render+video group membership to access /dev/dri/renderD128 in the container.
  users.users.jellyfin.extraGroups = [
    "render"
    "video"
  ];

  # --- Jellyfin ---
  # SSO plugin (9p4/jellyfin-plugin-sso) wired up in 5g alongside Caddy/authentik.
  services.jellyfin = {
    enable = true;
    openFirewall = true;
  };

  # --- Seerr (media request manager, formerly jellyseerr) ---
  # seerr-oidc: fork with OIDC login (michaelhthomas feat/oidc-login-basic).
  # OIDC is off by default; activate in 5g once Caddy provides HTTPS redirect URIs.
  # OIDC_ALLOW_INSECURE=true is needed because authentik runs on plain HTTP internally.
  services.seerr = {
    enable = true;
    openFirewall = true;
    package = pkgs.seerr-oidc;
  };
  systemd.services.seerr.environment.OIDC_ALLOW_INSECURE = "true";

  # --- NFS mounts from minz-arr-0 ---
  # Both paths must be mounted at the same absolute paths as on arr-0 so that
  # symlinks from /data/library → /data/downloads → /mnt/decypharr resolve.
  # NFS4 mount syscall interception is enabled in the Incus container config.
  fileSystems."/data" = {
    device = "${arrIp}:/data";
    fsType = "nfs";
    options = [
      "ro"
      "nfsvers=4"
      "noatime"
      "_netdev"
      "x-systemd.automount"
      "x-systemd.idle-timeout=600"
    ];
  };

  fileSystems."/mnt/decypharr" = {
    device = "${arrIp}:/mnt/decypharr";
    fsType = "nfs";
    options = [
      "ro"
      "nfsvers=4"
      "noatime"
      "_netdev"
      "x-systemd.automount"
      "x-systemd.idle-timeout=600"
    ];
  };

  # rpc_pipefs (sunrpc) cannot be mounted in an unprivileged container.
  # suppressedSystemUnits only covers upstream/NixOS-defined units — this unit
  # comes from nfs-utils via systemd.packages, so a ConditionVirtualization
  # drop-in is the right approach (same pattern as systemd-remount-fs).
  systemd.units."var-lib-nfs-rpc_pipefs.mount" = {
    overrideStrategy = "asDropin";
    text = ''
      [Unit]
      ConditionVirtualization=!container
    '';
  };

  systemd.tmpfiles.rules = [
    "d /data          0755 root root -"
    "d /mnt/decypharr 0755 root root -"
  ];

  networking.firewall.allowedTCPPorts = [ jellyfinPort ];
}
