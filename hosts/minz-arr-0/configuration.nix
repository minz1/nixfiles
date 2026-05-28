{ hostName, config, ... }:

let
  topology = import ../../common/topology.nix;
  node = topology.nodes."${hostName}";
in
{
  imports = [
    ../../modules/services/decypharr.nix
    ../../modules/nixos/rootless-podman.nix
  ];

  networking.hostName = hostName;
  system.stateVersion = "25.11";

  sops.secrets.sonarr_api_key = { };
  sops.secrets.radarr_api_key = { };
  sops.secrets.prowlarr_api_key = { };
  sops.secrets.aiostreams_env.owner = "oci";

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
  systemd.services.sonarr.serviceConfig.EnvironmentFile = config.sops.secrets.sonarr_api_key.path;

  services.radarr = {
    enable = true;
    openFirewall = true;
  };
  systemd.services.radarr.serviceConfig.EnvironmentFile = config.sops.secrets.radarr_api_key.path;

  services.prowlarr = {
    enable = true;
    openFirewall = true;
  };
  systemd.services.prowlarr.serviceConfig.EnvironmentFile = config.sops.secrets.prowlarr_api_key.path;

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
      # BASE_URL updated to public URL in 5g (Caddy)
      environment.BASE_URL = "http://10.10.0.4:8080";
      environmentFiles = [ config.sops.secrets.aiostreams_env.path ];
      podman.user = "oci";
    };
  };

  # --- NFS server ---
  # Exports /data (library + downloads) and /mnt/decypharr (VFS) to
  # the Incus host (minz-home-nix-0). The host then bind-mounts these into
  # the unprivileged jellyfin container to avoid mount syscall issues.
  services.nfs.server = {
    enable = true;
    exports = ''
      # insecure: required for unprivileged container ports
      # all_squash: mitigates spoofing by forcing all requests to nobody (UID 99)
      /data          10.10.0.1(ro,no_subtree_check,fsid=1,insecure,all_squash,anonuid=99,anongid=99)
      /mnt/decypharr 10.10.0.1(ro,no_subtree_check,fsid=2,insecure,all_squash,anonuid=99,anongid=99)
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
