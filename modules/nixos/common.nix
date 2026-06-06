{ config, lib, ... }:

let
  topology = import ../../common/topology.nix;
  sshKeys = import ../../common/ssh-keys.nix;
  me = topology.nodes.${config.networking.hostName} or { };
  myNetworks = builtins.attrNames (me.networks or { });
  resolve = _: node:
    let
      shared = builtins.filter
        (net: (node.networks or { }) ? ${net} && (node.networks.${net} ? ip))
        myNetworks;
    in
    if shared == [ ] then null else node.networks.${builtins.head shared}.ip;
  entries = lib.filterAttrs (_: v: v != null)
    (lib.mapAttrs resolve
      (lib.filterAttrs (n: _: n != config.networking.hostName) topology.nodes));
in
{
  networking.extraHosts = lib.concatStringsSep "\n"
    (lib.mapAttrsToList (name: ip: "${ip}  ${name}.internal") entries);

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
