{ ... }:

let
  sshKeys = import ../../common/ssh-keys.nix;
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
    openssh.authorizedKeys.keys = sshKeys.minz1 ++ (sshKeys.deploy or [ ]);
  };

  nix.settings.trusted-users = [ "minz1" ];
  security.sudo.wheelNeedsPassword = false;
  users.mutableUsers = false;
  zramSwap.enable = true;
  programs.neovim.enable = true;
}
