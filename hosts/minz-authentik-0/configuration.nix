{
  hostName,
  config,
  authentik-nix,
  ...
}:

let
  topology = import ../../common/topology.nix;
  node = topology.nodes."${hostName}";
  authentikPort = node.services.authentik.port;
  ldapPort = node.services.ldap.port;
in
{
  imports = [ authentik-nix.nixosModules.default ];

  networking.hostName = hostName;
  system.stateVersion = "25.11";

  sops.secrets.authentik_env.mode = "0400";
  sops.secrets.authentik_ldap_token.mode = "0400";

  sops.templates.authentik-ldap-env = {
    content = ''
      AUTHENTIK_HOST=http://localhost:${toString authentikPort}
      AUTHENTIK_INSECURE=false
      AUTHENTIK_TOKEN=${config.sops.placeholder.authentik_ldap_token}
    '';
    mode = "0400";
  };

  services.authentik = {
    enable = true;
    environmentFile = config.sops.secrets.authentik_env.path;
    settings = {
      disable_startup_analytics = true;
      avatars = "none";
      email = {
        host = "smtp.resend.com";
        port = 587;
        username = "resend";
        use_tls = true;
        use_ssl = false;
        from = "noreply@minz1.com";
      };
    };
  };

  services.authentik-ldap = {
    enable = true;
    environmentFile = config.sops.templates.authentik-ldap-env.path;
  };

  swapDevices = [
    {
      device = "/persist/swapfile";
      size = 2048;
    }
  ];

  networking.firewall.allowedTCPPorts = [
    authentikPort
    ldapPort
  ];

  environment.persistence."/persist".directories = [
    # DynamicUser: real state is at /var/lib/private/authentik; /var/lib/authentik is a symlink.
    {
      directory = "/var/lib/private/authentik";
      mode = "0700";
    }
    {
      directory = "/var/lib/postgresql";
      user = "postgres";
      group = "postgres";
      mode = "0750";
    }
  ];
}
