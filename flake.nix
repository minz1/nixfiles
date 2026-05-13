{
  description = "minz1 NixOS configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    deploy-rs.url = "github:serokell/deploy-rs";
  };

  outputs =
    {
      self,
      nixpkgs,
      deploy-rs,
    }:
    let
      system = "x86_64-linux";
      overlay = import ./pkgs;
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ overlay ];
      };
      deployPkgs = import nixpkgs {
        inherit system;
        overlays = [
          deploy-rs.overlays.default
          (self: super: {
            deploy-rs = {
              inherit (pkgs) deploy-rs;
              lib = super.deploy-rs.lib;
            };
          })
        ];
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

      deploy.nodes.minz-vultr-nix-0 = {
        hostname = "10.8.0.1";
        sshUser = "minz1";
        profiles.system = {
          user = "root";
          path = deployPkgs.deploy-rs.lib.activate.nixos self.nixosConfigurations.minz-vultr-nix-0;
        };
      };

      deploy.nodes.minz-home-vm-0 = {
        hostname = "10.8.0.5";
        sshUser = "minz1";
        profiles.system = {
          user = "root";
          path = deployPkgs.deploy-rs.lib.activate.nixos self.nixosConfigurations.minz-home-vm-0;
        };
      };

      checks = builtins.mapAttrs (
        system: deployLib: deployLib.deployChecks self.deploy
      ) deployPkgs.deploy-rs.lib;

      packages.${system} = {
        inherit (pkgs) decypharr;
        deploy-rs = deployPkgs.deploy-rs.deploy-rs;
      };
    };
}
