{ config, lib, ... }:

let
  topology = import ../../common/topology.nix;
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
    # overridable: hosts whose own Caddy already owns :80 (e.g. vultr-nix-1) need an alt port (docs/main-plan.md S4)
    listenHTTP = lib.mkDefault ":80";
    group = "caddy";
    reloadServices = lib.optional config.services.caddy.enable "caddy.service";
    extraDomainNames = allHostIps;
  };

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
    openssh.authorizedKeys.keys = sshKeys.minz1 ++ (sshKeys.deploy or [ ]);
  };

  nix.settings.trusted-users = [ "minz1" ];

  # Fleet-wide GC: bound Nix store growth on every host (most Incus VM /nix
  # partitions are 10-30G). nix.gc is a weekly time-based sweep + store GC;
  # configurationLimit is a per-activation, count-based backstop so a burst
  # of same-day deploys can't accumulate unbounded generations/boot entries
  # between weekly GC runs. Both are complementary, not redundant.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nix.optimise.automatic = true;

  # No-op on hosts without systemd-boot (e.g. the minz-media-0 LXC container);
  # only consumed by the systemd-boot activation script (vm.nix, baremetal.nix).
  boot.loader.systemd-boot.configurationLimit = lib.mkDefault 10;
  security.sudo.wheelNeedsPassword = false;
  users.mutableUsers = false;
  zramSwap.enable = true;
  programs.neovim.enable = true;
}
