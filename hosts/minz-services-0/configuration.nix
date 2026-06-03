{
  hostName,
  config,
  ...
}:

let
  topology = import ../../common/topology.nix;
  node = topology.nodes."${hostName}";
  memosPort = node.services.memos.port;
in
{
  networking.hostName = hostName;
  system.stateVersion = "25.11";

  services.memos = {
    enable = true;
    # Setting any attribute replaces the entire module default — carry all needed vars.
    # MEMOS_ADDR: 0.0.0.0 so Caddy can reach it over incus_bridge (default is 127.0.0.1).
    settings = {
      MEMOS_MODE = "prod";
      MEMOS_ADDR = "0.0.0.0";
      MEMOS_PORT = toString memosPort;
      MEMOS_DATA = "/var/lib/memos/";
      MEMOS_DRIVER = "sqlite";
      MEMOS_INSTANCE_URL = "https://memos.minz1.com";
    };
  };

  # openFirewall=true references cfg.port which doesn't exist in the module — open manually.
  networking.firewall.allowedTCPPorts = [ memosPort ];

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/memos";
      user = config.services.memos.user;
      group = config.services.memos.group;
      mode = "0750";
    }
  ];
}
