{ hostName, ... }:

let
  topology = import ../../common/topology.nix;
  node = topology.nodes."${hostName}";
  jellyfinIp = topology.nodes."minz-jellyfin-0".networks.incus_bridge.ip;
in
{
  imports = [
    ../../modules/services/decypharr.nix
    ../../modules/nixos/rootless-podman.nix
  ];

  networking.hostName = hostName;
  system.stateVersion = "25.11";

  services.rootless-podman = {
    enable = true;
    user = "oci";
    uid = 902;
  };

  # Shared group — sonarr, radarr, bazarr, decypharr all need /data rw
  users.groups.media = { };
  users.users.sonarr.extraGroups = [ "media" ];
  users.users.radarr.extraGroups = [ "media" ];
  users.users.bazarr.extraGroups = [ "media" ];

  # --- Arr services ---

  services.sonarr = {
    enable = true;
    openFirewall = true;
  };

  services.radarr = {
    enable = true;
    openFirewall = true;
  };

  services.prowlarr = {
    enable = true;
    openFirewall = true;
  };

  services.bazarr = {
    enable = true;
    openFirewall = true;
  };

  services.recyclarr.enable = true;

  # --- Decypharr ---

  services.decypharr = {
    enable = true;
    mediaPath = "/mnt/decypharr";
    mediaGroup = "media";
    port = node.services.decypharr.port;
  };

  # --- OCI containers (rootless podman, user: oci / uid: 902) ---
  # flaresolverr: Cloudflare bypass proxy for Prowlarr — localhost only
  # zilean:       DMM debrid indexer for Prowlarr — localhost only
  # aiostreams:   Debrid stream aggregator — internal for now, exposed via Caddy in 5g

  virtualisation.oci-containers.containers = {
    flaresolverr = {
      image = "ghcr.io/flaresolverr/flaresolverr:latest";
      ports = [ "127.0.0.1:8191:8191" ];
      environment.LOG_LEVEL = "info";
      podman.user = "oci";
    };
    zilean = {
      image = "ipromknight/zilean:latest";
      ports = [ "127.0.0.1:8181:8181" ];
      volumes = [ "/persist/zilean:/app/data" ];
      podman.user = "oci";
    };
    aiostreams = {
      image = "viren070/aiostreams:latest";
      ports = [ "127.0.0.1:8080:8080" ];
      podman.user = "oci";
    };
  };

  # --- NFS server ---
  # Exports /data (library + downloads) and /mnt/decypharr (VFS) to
  # minz-jellyfin-0. jellyfin follows the full symlink chain:
  #   /data/library/… → /data/downloads/… → /mnt/decypharr/…
  # so both exports must be mounted at the same absolute paths on the client.
  #
  # Note: /mnt/decypharr is a user-space FUSE mount. root bypasses DAC on
  # Linux so nfsd can read it without allow_other; verify on first deploy.
  services.nfs.server = {
    enable = true;
    exports = ''
      /data          ${jellyfinIp}(ro,no_subtree_check,fsid=1)
      /mnt/decypharr ${jellyfinIp}(ro,no_subtree_check,fsid=2)
    '';
  };

  # --- Filesystem layout ---
  systemd.tmpfiles.rules = [
    "d /persist/zilean            0700 oci    oci    -"
    "d /data                     0755 root   root   -"
    "d /data/downloads           0775 root   media  -"
    "d /data/downloads/sonarr    0775 sonarr media  -"
    "d /data/downloads/radarr    0775 radarr media  -"
    "d /data/library             0775 root   media  -"
    "d /data/library/tv          0775 sonarr media  -"
    "d /data/library/movies      0775 radarr media  -"
  ];

  networking.firewall.allowedTCPPorts = [
    2049 # NFS
    node.services.decypharr.port
    node.services.bazarr.port
  ];

  swapDevices = [
    {
      device = "/persist/swapfile";
      size = 2048;
    }
  ];

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/sonarr";
      user = "sonarr";
      group = "sonarr";
      mode = "0700";
    }
    {
      directory = "/var/lib/radarr";
      user = "radarr";
      group = "radarr";
      mode = "0700";
    }
    {
      directory = "/var/lib/private/prowlarr";
      mode = "0700";
    }
    {
      directory = "/var/lib/bazarr";
      user = "bazarr";
      group = "bazarr";
      mode = "0700";
    }
    {
      directory = "/var/lib/decypharr";
      user = "decypharr";
      group = "decypharr";
      mode = "0700";
    }
    {
      directory = "/data";
      mode = "0755";
    }
    {
      directory = "/var/lib/oci";
      user = "oci";
      group = "oci";
      mode = "0750";
    }
  ];
}
