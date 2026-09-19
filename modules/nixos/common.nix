{
  config,
  lib,
  topology,
  ...
}:

let
  sshKeys = import ../../common/ssh-keys.nix;
  me = topology.nodes.${config.networking.hostName} or { };
  myNetworks = builtins.attrNames (me.networks or { });
  resolve =
    _: node:
    let
      shared = builtins.filter (
        net: (node.networks or { }) ? ${net} && (node.networks.${net} ? ip)
      ) myNetworks;
    in
    if shared != [ ] then
      node.networks.${builtins.head shared}.ip
    else if (node.networks or { }) ? mgmt then
      node.networks.mgmt.ip
    else if (node.networks or { }) ? incus_bridge then
      node.networks.incus_bridge.ip
    else
      null;
  entries = lib.filterAttrs (_: v: v != null) (
    lib.mapAttrs resolve (lib.filterAttrs (n: _: n != config.networking.hostName) topology.nodes)
  );
  pkiPort = 9443;
  allHostIps = lib.filter (ip: ip != null) (
    lib.mapAttrsToList (name: net: if name != "edge" then (net.ip or null) else null) (
      me.networks or { }
    )
  );
in
{
  networking.extraHosts = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: ip: "${ip}  ${name}.internal") entries
  );

  security.acme.acceptTerms = true;
  security.acme.defaults.server = lib.mkDefault "https://minz-pki-0.internal:${toString pkiPort}/acme/acme/directory";
  security.acme.defaults.email = lib.mkDefault "emerytang@gmail.com";
  security.acme.defaults.renewInterval = "*-*-* 0/6:00:00";
  security.acme.certs."${config.networking.hostName}.internal" = {
    # overridable: hosts whose own Caddy already owns :80 (e.g. vultr-nix-1) need an alt port
    listenHTTP = lib.mkDefault ":80";
    group = "caddy";
    reloadServices = lib.optional config.services.caddy.enable "caddy.service";
    extraDomainNames = allHostIps;
  };

  # Upstream's 24h RandomizedDelaySec+FixedRandomDelay pushes the real renewal period to 6-24h
  # per host, against step-ca's 24h certs. Keep the jitter small and retry failed orders.
  systemd.timers."acme-renew-${config.networking.hostName}.internal".timerConfig = {
    RandomizedDelaySec = lib.mkForce "30m";
    FixedRandomDelay = lib.mkForce false;
    AccuracySec = lib.mkForce "1m";
  };
  systemd.services."acme-order-renew-${config.networking.hostName}.internal".serviceConfig.Restart =
    "on-failure";

  # reloadServices only reloads Caddy after a renewal — it doesn't order startup, so a full
  # reboot can race Caddy's first read of cert.pem against the cert's first-ever issuance.
  systemd.services.caddy = lib.mkIf config.services.caddy.enable {
    after = [ "acme-${config.networking.hostName}.internal.service" ];
    wants = [ "acme-${config.networking.hostName}.internal.service" ];
  };

  # The internal cert above is group caddy; hosts without Caddy still need the group so Alloy/node_exporter can read it.
  users.groups.caddy = { };

  # NixOS ACME module doesn't auto-open the listenHTTP port; add it here.
  networking.firewall.allowedTCPPorts = [ 80 ];

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
      AllowTcpForwarding = false;
      AllowAgentForwarding = false;
    };
    startWhenNeeded = false;
  };

  users.users.minz1 = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = sshKeys.minz1;
  };

  nix.settings.trusted-users = [ "minz1" ];

  # Fleet-wide GC: weekly time-based sweep; min-free/max-free below is the actual burst backstop.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nix.settings.min-free = 1024 * 1024 * 1024; # 1 GiB — GC kicks in below this
  nix.settings.max-free = 3 * 1024 * 1024 * 1024; # free up to this, then stop
  nix.optimise.automatic = true;

  # No-op on hosts without systemd-boot (e.g. the minz-media-0 LXC container).
  boot.loader.systemd-boot.configurationLimit = lib.mkDefault 10;
  security.sudo.wheelNeedsPassword = false;
  users.mutableUsers = false;
  zramSwap.enable = true;
  programs.neovim.enable = true;
}
