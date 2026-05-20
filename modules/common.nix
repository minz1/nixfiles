{ ... }:

let
  sshKeys = (import ../common/ssh-keys.nix).minz1;
in
{
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
  zramSwap.enable = true;
  programs.neovim.enable = true;
}
