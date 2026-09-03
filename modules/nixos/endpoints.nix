{ lib, ... }:
{
  options.homelab.endpoints = lib.mkOption {
    default = { };
    description = "Named service endpoints this host exposes for cross-host consumption.";
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          ip = lib.mkOption {
            type = lib.types.str;
            description = "IP address of the endpoint (no hostname).";
          };
          port = lib.mkOption {
            type = lib.types.port;
            description = "TCP port.";
          };
          tls = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether the endpoint speaks TLS.";
          };
        };
      }
    );
  };
}
