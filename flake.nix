{
  description = "minz1 NixOS configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      overlay = import ./pkgs;
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ overlay ];
      };
    in
    {
      nixosConfigurations.minz-vultr-nix-0 = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./modules/base.nix
          ./hosts/minz-vultr-nix-0/configuration.nix
          ./modules/services/decypharr.nix
          {
            nixpkgs.overlays = [ overlay ];
          }
        ];
      };

      nixosConfigurations.minz-home-vm-0 = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./modules/base.nix
          ./hosts/minz-home-vm-0/configuration.nix
          ./modules/services/decypharr.nix
          {
            nixpkgs.overlays = [ overlay ];
          }
        ];
      };

      packages.${system} = {
        inherit (pkgs) decypharr;
      };
    };
}
