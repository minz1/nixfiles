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
            deploy-rs = super.deploy-rs // {
              inherit (pkgs) deploy-rs;
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

      deploy.nodes =
        let
          topology = import ./common/topology.nix;
          nixosNodes = nixpkgs.lib.filterAttrs (_: node: node.os == "nixos") topology.nodes;
        in
        builtins.mapAttrs (name: node: {
          hostname = node.networks.mgmt.ip;
          sshUser = node.sshUser;
          profiles.system = {
            user = "root";
            path = deployPkgs.deploy-rs.lib.activate.nixos self.nixosConfigurations.${name};
          };
        }) nixosNodes;

      checks = builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) deploy-rs.lib;

      packages.${system} = {
        inherit (pkgs) decypharr;
        deploy-rs = deployPkgs.deploy-rs.deploy-rs;
      };
    };
}
