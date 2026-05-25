{ ... }:

{
  imports = [ ../../modules/services/decypharr.nix ];

  system.stateVersion = "25.11";

  services.decypharr = {
    enable = true;
    mediaPath = "/persist/media";
  };

  environment.persistence."/persist".directories = [
    "/var/lib/decypharr"
  ];
}
