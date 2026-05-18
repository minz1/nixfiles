{
  description = "minz1 NixOS configurations";

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
      # All nodes declared in topology with os = "nixos" get a NixOS configuration
      # and a deploy-rs node automatically. Adding a new host only requires a
      # topology entry and a hosts/<name>/configuration.nix file.
      nixosNodes = nixpkgs.lib.filterAttrs (_: n: n.os == "nixos") topology.nodes;

      # Hosts that have a NixOS configuration to build. Incus VMs are excluded
      # until OpenTofu provisions them and set deployed = true.
      configurableNodes = nixpkgs.lib.filterAttrs (
        _: node: if (node.provisioner or "") == "incus" then node.deployed or false else true
      ) nixosNodes;

      # Nodes that are also provisioned by Incus use their incus_bridge IP for deploy-rs.
      # This is because the mgmt (WireGuard) tunnel doesn't route to VMs directly
      # from the runner — the Incus bridge on the host VM provides L2 adjacency.
      deployHostname =
        name: node:
        if node.provisioner or "" == "incus" then node.networks.incus_bridge.ip else node.networks.mgmt.ip;

      # Deployable NixOS nodes: only those that have been provisioned (or don't need provisioning).
      # VMs with `deployed = false` are skipped until OpenTofu creates them.
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
    in
    {
      nixosConfigurations = builtins.mapAttrs (
        name: _:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            sops-nix.nixosModules.sops
            rustfs.nixosModules.rustfs
            { services.rustfs.package = rustfs.packages.${system}.default; }
            ./modules/base.nix
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
      };
    };
}
