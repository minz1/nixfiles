{
  hostName,
  config,
  ...
}:

let
  topology = import ../../common/topology.nix;
  node = topology.nodes."${hostName}";
  pkiIp = node.networks.incus_bridge.ip;
  stepCaPort = 9443;
in
{
  networking.hostName = hostName;
  system.stateVersion = "25.11";

  environment.etc."step-ca/certs/root_ca.crt".source = ./root_ca.crt;
  environment.etc."step-ca/certs/intermediate_ca.crt".source = ./intermediate_ca.crt;

  sops.secrets.step_ca_password = {
    mode = "0400";
    owner = "step-ca";
  };

  sops.secrets.step_ca_intermediate_key = {
    path = "/run/secrets/step_ca_intermediate_key";
    owner = "step-ca";
  };

  services.step-ca = {
    enable = true;
    address = "0.0.0.0";
    port = stepCaPort;
    settings = (builtins.fromJSON (builtins.readFile ./ca.json)) // {
      root = "/etc/step-ca/certs/root_ca.crt";
      crt = "/etc/step-ca/certs/intermediate_ca.crt";
      key = "/run/secrets/step_ca_intermediate_key";
      db = {
        type = "badgerv2";
        dataSource = "/var/lib/step-ca/db";
        badgerFileLoadingMode = "";
      };
    };
    intermediatePasswordFile = config.sops.secrets.step_ca_password.path;
  };

  # No Caddy on this host, but group is needed for ACME cert readability by Alloy.
  users.groups.caddy = { };

  networking.firewall.allowedTCPPorts = [ stepCaPort ];

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/private/step-ca";
      mode = "0700";
    }
  ];
}
