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
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-anywhere = {
      url = "github:nix-community/nixos-anywhere";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.disko.follows = "disko";
    };
    impermanence.url = "github:nix-community/impermanence";
    authentik-nix = {
      url = "github:nix-community/authentik-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    lanzaboote = {
      url = "github:nix-community/lanzaboote/v1.0.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    quadlet-nix.url = "github:SEIAROTg/quadlet-nix";
  };

  outputs =
    {
      self,
      nixpkgs,
      deploy-rs,
      sops-nix,
      rustfs,
      disko,
      nixos-anywhere,
      impermanence,
      authentik-nix,
      lanzaboote,
      quadlet-nix,
    }:
    let
      system = "x86_64-linux";
      overlay = import ./pkgs;
      topology = import ./common/topology.nix;

      # Shared overlay list — used for both the top-level pkgs and per-host nixpkgs.overlays.
      overlays = [
        rustfs.overlays.default
        overlay
      ];

      nixosNodes = nixpkgs.lib.filterAttrs (_: n: n.os == "nixos") topology.nodes;

      # All nodes declared in topology with os = "nixos" get a NixOS configuration
      # and a deploy-rs node automatically. Adding a new host only requires a
      # topology entry and a hosts/<name>/configuration.nix file.
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
        inherit overlays;
      };

      # deploy-rs shim: re-use the deploy-rs binary from our main pkgs evaluation
      # rather than letting deployPkgs build a second copy. Without this, Nix would
      # build deploy-rs twice (once for pkgs, once for deployPkgs) even though
      # the inputs are identical, wasting significant build time.
      deployPkgs = import nixpkgs {
        inherit system;
        overlays = [
          deploy-rs.overlays.default
          (_: super: {
            deploy-rs = super.deploy-rs // {
              inherit (pkgs) deploy-rs;
            };
          })
        ];
      };

      # Bootstrap image target — a NixOS eval just for building the golden image.
      # nixos-rebuild build-image --image-variant incus --flake .#bootstrapImage
      # or: nix build .#bootstrap-image
      bootstrapImage = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./modules/profiles/bootstrap.nix
        ];
      };

      bootstrapContainerImage = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./modules/profiles/bootstrap-container.nix
        ];
      };
    in
    {
      nixosConfigurations = builtins.mapAttrs (
        name: _:
        let
          node = topology.nodes.${name} or { };
          isContainer =
            (node.provisioner or "") == "incus" && (node.incus.incus_type or "virtual-machine") == "container";
          isVm = (node.provisioner or "") == "incus" && !isContainer;
          isBareMetal = !isVm && !isContainer && (node ? storage);
          vmModule =
            if isVm then
              [
                disko.nixosModules.disko
                impermanence.nixosModules.impermanence
                ./modules/profiles/vm.nix
                ./modules/nixos/impermanence.nix
              ]
            else
              [ ];
          containerModule =
            if isContainer then
              [
                impermanence.nixosModules.impermanence
                ./modules/profiles/container.nix
              ]
            else
              [ ];
          baremetalModule =
            if isBareMetal then
              [
                disko.nixosModules.disko
                impermanence.nixosModules.impermanence
                ./modules/profiles/baremetal.nix
                ./modules/nixos/impermanence.nix
              ]
            else
              [ ];
        in
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = {
            hostName = name;
            inherit lanzaboote authentik-nix;
          };
          modules = [
            sops-nix.nixosModules.sops
            quadlet-nix.nixosModules.quadlet
            rustfs.nixosModules.rustfs
            { services.rustfs.package = rustfs.packages.${system}.default; }
            ./modules/nixos/base.nix
          ]
          ++ vmModule
          ++ containerModule
          ++ baremetalModule
          ++ [
            (./hosts + "/${name}/configuration.nix")
            { nixpkgs.overlays = overlays; }
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

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          just
          sops
          opentofu
          awscli2
          nix-update
          deployPkgs.deploy-rs.deploy-rs
        ];
      };

      formatter.${system} = pkgs.nixfmt;

      packages.${system} = {
        inherit (pkgs) decypharr seerr-oidc;
        deploy-rs = deployPkgs.deploy-rs.deploy-rs;
        nixos-anywhere = nixos-anywhere.packages.${system}.nixos-anywhere;
        incus-bootstrap-image = pkgs.runCommand "nixos-bootstrap-incus" { } ''
          mkdir -p $out
          ln -s ${bootstrapImage.config.system.build.qemuImage}/nixos.qcow2 $out/nixos.qcow2
          ln -s ${bootstrapImage.config.system.build.metadata}/tarball/*.tar.xz $out/metadata.tar.xz
        '';
        incus-bootstrap-container-image = pkgs.runCommand "nixos-bootstrap-incus-container" { } ''
          mkdir -p $out
          ln -s ${bootstrapContainerImage.config.system.build.tarball}/tarball/*.tar.xz $out/rootfs.tar.xz
          ln -s ${bootstrapContainerImage.config.system.build.metadata}/tarball/*.tar.xz $out/metadata.tar.xz
        '';
      };
    };
}
