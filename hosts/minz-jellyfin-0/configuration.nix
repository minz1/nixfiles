{
  hostName,
  config,
  pkgs,
  ...
}:

let
  topology = import ../../common/topology.nix;
  node = topology.nodes."${hostName}";
  jellyfinPort = node.services.jellyfin.port;
in
{
  imports = [ ../../modules/services/jellyfin-init.nix ];

  networking.hostName = hostName;
  system.stateVersion = "25.11";

  sops.secrets.jellyfin_admin_password.mode = "0400";
  services.jellyfin-init = {
    enable = true;
    adminPasswordFile = config.sops.secrets.jellyfin_admin_password.path;
  };

  # Arc A310 DRM passthrough via Incus cgroup allowlist; VAAPI device: /dev/dri/renderD129
  hardware.graphics.enable = true;
  hardware.graphics.extraPackages = with pkgs; [
    intel-media-driver
    intel-compute-runtime
    vpl-gpu-rt # Required for Intel Arc (DG2) QuickSync support
  ];

  # jellyfin needs render+video group membership to access /dev/dri/renderD128 in the container.
  users.users.jellyfin.extraGroups = [
    "render"
    "video"
  ];

  services.jellyfin = {
    enable = true;
    openFirewall = true;
  };

  services.seerr = {
    enable = true;
    openFirewall = true;
  };

  # /data and /mnt/decypharr are Incus disk devices from the host; no mount syscall inside container.
  systemd.tmpfiles.rules = [
    "d /data          0755 root root -"
    "d /mnt/decypharr 0755 root root -"
  ];

  networking.firewall.allowedTCPPorts = [ jellyfinPort ];
}
