{ hostName, config, authentik-nix, ... }:

let
  topology = import ../../common/topology.nix;
  node = topology.nodes."${hostName}";
  authentikPort = node.services.authentik.port;
in
{
  imports = [ authentik-nix.nixosModules.default ];

  networking.hostName = hostName;
  system.stateVersion = "25.11";

  sops.defaultSopsFile = ../../secrets/minz-authentik-0.yaml;

  sops.secrets.authentik_env.mode = "0400";

  services.authentik = {
    enable = true;
    environmentFile = config.sops.secrets.authentik_env.path;
    settings = {
      disable_startup_analytics = true;
      avatars = "none";
    };
  };

  swapDevices = [ { device = "/persist/swapfile"; size = 2048; } ];

  networking.firewall.allowedTCPPorts = [ authentikPort ];

  environment.persistence."/persist".directories = [
    # DynamicUser: real state is at /var/lib/private/authentik; /var/lib/authentik is a symlink.
    { directory = "/var/lib/private/authentik"; mode = "0700"; }
    { directory = "/var/lib/postgresql"; user = "postgres"; group = "postgres"; mode = "0750"; }
  ];
}
