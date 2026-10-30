{
  hostName,
  config,
  node,
  topology,
  ...
}:

let
  atticIp = node.networks.incus_bridge.ip;
  caddyHttpsPort = topology.services.attic.port;
  atticPort = 8080;
in
{
  system.stateVersion = "25.11";

  # restartUnits, not restartTriggers: the template's *text* only contains a placeholder, so it
  # doesn't change when the secret's value is rotated. sops-nix compares decrypted values.
  sops.secrets.attic_jwt_secret.restartUnits = [ "atticd.service" ];

  sops.templates."attic-env".content = ''
    ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64=${config.sops.placeholder.attic_jwt_secret}
  '';

  # nixpkgs' atticd unit is already stricter than mkHardened (ProtectSystem=strict, no caps) — don't stack it.
  services.atticd = {
    enable = true;
    environmentFile = config.sops.templates."attic-env".path;
    settings = {
      listen = "127.0.0.1:${toString atticPort}";
      api-endpoint = "https://${hostName}.internal/";
      allowed-hosts = [
        "${hostName}.internal"
        atticIp
      ];
      garbage-collection = {
        interval = "12 hours";
        default-retention-period = "30 days";
      };
    };
  };

  homelab.internalProxy.servers.attic = {
    port = caddyHttpsPort;
    routes = [
      {
        match = [
          {
            host = [
              "${hostName}.internal"
              atticIp
            ];
          }
        ];
        handle = [
          {
            handler = "reverse_proxy";
            upstreams = [ { dial = "localhost:${toString atticPort}"; } ];
            headers.request.set."Host" = [ "{http.request.host}" ];
          }
        ];
      }
    ];
  };

  networking.firewall.allowedTCPPorts = [
    caddyHttpsPort
  ];

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/private/atticd";
      mode = "0700";
    }
  ];
}
