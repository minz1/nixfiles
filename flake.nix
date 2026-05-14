{
  description = "minz1 NixOS configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    deploy-rs.url = "github:serokell/deploy-rs";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      deploy-rs,
      sops-nix,
    }:
    let
      system = "x86_64-linux";
      overlay = import ./pkgs;
      topology = import ./common/topology.nix;
      # All nodes declared in topology with os = "nixos" get a NixOS configuration
      # and a deploy-rs node automatically. Adding a new host only requires a
      # topology entry and a hosts/<name>/configuration.nix file.
      nixosNodes = nixpkgs.lib.filterAttrs (_: n: n.os == "nixos") topology.nodes;
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
      nixosConfigurations = builtins.mapAttrs (
        name: _:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            sops-nix.nixosModules.sops
            ./modules/base.nix
            (./hosts + "/${name}/configuration.nix")
            { nixpkgs.overlays = [ overlay ]; }
          ];
        }
      ) nixosNodes;

      deploy.nodes = builtins.mapAttrs (name: node: {
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
