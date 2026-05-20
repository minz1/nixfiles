{
  ...
}:

{
  imports = [
    ../../modules/vm-hardware.nix
  ];

  networking.hostName = "minz-vm-nixos-0";
  system.stateVersion = "25.11";
}
