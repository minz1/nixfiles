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
    lib.mapAttrsToList (
      name: net: if name != "edge" then (net.ip or null) else null
    ) (me.networks or { })
  );
in
{
  networking.extraHosts = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: ip: "${ip}  ${name}.internal") entries
  );

  security.acme.acceptTerms = true;
  security.acme.defaults.server = lib.mkDefault "https://minz-pki-0.internal:${toString pkiPort}/acme/acme/directory";
  security.acme.defaults.email = lib.mkDefault "emerytang@gmail.com";
  security.acme.certs."${config.networking.hostName}.internal" = {
    listenHTTP = ":80";
    group = "caddy";
    reloadServices = lib.optional config.services.caddy.enable "caddy.service";
    extraDomainNames = allHostIps;
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
    startWhenNeeded = false;
  };

  users.users.minz1 = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = sshKeys.minz1 ++ (sshKeys.deploy or [ ]);
  };

  nix.settings.trusted-users = [ "minz1" ];
  security.sudo.wheelNeedsPassword = false;
  users.mutableUsers = false;
  zramSwap.enable = true;
  programs.neovim.enable = true;
}
