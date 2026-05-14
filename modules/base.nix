{ config, ... }:

let
  sshKeys = (import ../common/ssh-keys.nix).minz1;
  mgmtInterface = (import ../common/topology.nix).networks.mgmt.interface;
in
{
  imports = [ ../common/wireguard.nix ];
  networking.firewall = {
    enable = true;
    allowedUDPPorts = [ 51820 ];
    trustedInterfaces = [ "wg0" ];
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  users.users.minz1 = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = sshKeys;
  };

  nix.settings.trusted-users = [ "minz1" ];

  security.sudo.wheelNeedsPassword = false;

  # sops-nix: derive the age decryption key from the host's SSH ed25519 host key.
  # This key is generated on first boot and never changes — no separate age key to manage.
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  # SSH listens only on the WireGuard interface, so it must start after the tunnel is up.
  # Interface name sourced from topology — not coupled to wireguard.nix.
  systemd.services.sshd.after = [ "wireguard-${mgmtInterface}.service" ];
  systemd.services.sshd.wants = [ "wireguard-${mgmtInterface}.service" ];
  sops.defaultSopsFile = ../secrets + "/${config.networking.hostName}.yaml";
  sops.secrets.wg_private.mode = "0400";

  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = true;
  services.logrotate.checkConfig = false;
  programs.neovim.enable = true;
}
