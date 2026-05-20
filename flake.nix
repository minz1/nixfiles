{
  description = "minz1's nixfiles";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    deploy-rs.url = "github:serokell/deploy-rs";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    rustfs = {
      url = "github:rustfs/rustfs-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      deploy-rs,
      sops-nix,
      rustfs,
    }:
    let
      system = "x86_64-linux";
      overlay = import ./pkgs;
      topology = import ./common/topology.nix;
      nixosNodes = nixpkgs.lib.filterAttrs (_: n: n.os == "nixos") topology.nodes;

      configurableNodes = nixpkgs.lib.filterAttrs (
        _: node: if (node.provisioner or "") == "incus" then node.deployed or false else true
      ) nixosNodes;

      deployHostname =
        name: node:
        if node.provisioner or "" == "incus" then node.networks.incus_bridge.ip else node.networks.mgmt.ip;

      deployableNodes =
        let
          filterDeployed =
            _: node: if (node.provisioner or "") == "incus" then (node.deployed or false) else true;
          filtered = nixpkgs.lib.filterAttrs filterDeployed nixosNodes;
          skipped = nixpkgs.lib.filterAttrs (
            _: node: (node.provisioner or "") == "incus" && !(node.deployed or false)
          ) nixosNodes;
        in
        builtins.trace (
          if skipped != { } then
            "nixfiles: skipping undeployed VMs: ${builtins.concatStringsSep ", " (builtins.attrNames skipped)}"
          else
            "nixfiles: all nodes deployed"
        ) filtered;

      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          rustfs.overlays.default
          overlay
        ];
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

      bootstrapImage = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./modules/vm-hardware.nix
          ./modules/bootstrap-image.nix
        ];
      };
    in
    {
      nixosConfigurations = builtins.mapAttrs (
        name: _:
        let
          node = topology.nodes.${name} or { };
          isVm = (node.provisioner or "") == "incus";
          vmModule = if isVm then [ ./modules/base-vm.nix ] else [ ];
        in
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = {
            hostName = name;
          };
          modules = [
            sops-nix.nixosModules.sops
            rustfs.nixosModules.rustfs
            { services.rustfs.package = rustfs.packages.${system}.default; }
            ./modules/base.nix
          ]
          ++ vmModule
          ++ [
            (./hosts + "/${name}/configuration.nix")
            {
              nixpkgs.overlays = [
                rustfs.overlays.default
                overlay
              ];
            }
          ];
        }
      ) configurableNodes;

      deploy.nodes = builtins.mapAttrs (name: node: {
        hostname = deployHostname name node;
        sshUser = node.sshUser;
        profiles.system = {
          user = "root";
          path = deployPkgs.deploy-rs.lib.activate.nixos self.nixosConfigurations.${name};
        };
      }) deployableNodes;

      checks = builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) deploy-rs.lib;

      packages.${system} = {
        inherit (pkgs) decypharr;
        deploy-rs = deployPkgs.deploy-rs.deploy-rs;
        incus-bootstrap-image = pkgs.runCommand "nixos-bootstrap-incus" { } ''
          mkdir -p $out
          ln -s ${bootstrapImage.config.system.build.qemuImage}/nixos.qcow2 $out/nixos.qcow2
          ln -s ${bootstrapImage.config.system.build.metadata}/tarball/*.tar.xz $out/metadata.tar.xz
        '';
      };
    };
}
