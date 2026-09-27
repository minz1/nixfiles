{
  description = "minz1's nixfiles";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    deploy-rs.url = "github:serokell/deploy-rs";
    sops-nix = {
      url = "github:Mic92/sops-nix";
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
      url = "github:nix-community/lanzaboote";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    quadlet-nix.url = "github:SEIAROTg/quadlet-nix";
    decypharr.url = "github:minz1/decypharr/minz";
    mediafixer.url = "github:minz1/media-fixer";
    whitelist-sync.url = "github:minz1/minecraft-whitelist-sync";
    nix-topology = {
      url = "github:oddlama/nix-topology";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      deploy-rs,
      sops-nix,
      disko,
      nixos-anywhere,
      impermanence,
      authentik-nix,
      lanzaboote,
      quadlet-nix,
      decypharr,
      mediafixer,
      whitelist-sync,
      nix-topology,
    }:
    let
      system = "x86_64-linux";
      overlay = import ./pkgs;
      topology = import ./common/topology.nix;

      overlays = [
        overlay
        nix-topology.overlays.default
      ];

      nixosNodes = nixpkgs.lib.filterAttrs (_: n: n.os == "nixos") topology.nodes;

      configurableNodes =
        let
          isDeployed = _: node: (node.provisioner or "") != "incus" || (node.deployed or false);
          skipped = nixpkgs.lib.filterAttrs (n: v: !isDeployed n v) nixosNodes;
        in
        nixpkgs.lib.warnIf (skipped != { })
          "nixfiles: skipping undeployed VMs: ${builtins.concatStringsSep ", " (builtins.attrNames skipped)}"
          (nixpkgs.lib.filterAttrs isDeployed nixosNodes);

      # incus nodes: bridge IP because the WG tunnel doesn't route to VMs from the runner
      deployHostname =
        _: node:
        if node.provisioner or "" == "incus" then node.networks.incus_bridge.ip else node.networks.mgmt.ip;

      deployableNodes = configurableNodes;

      # Dependency-ordered deploy phases, derived from the routing topology
      topologyList = nixpkgs.lib.mapAttrsToList (name: node: node // { inherit name; }) topology.nodes;
      mgmtHubName =
        (nixpkgs.lib.findFirst (n: n.networks.mgmt.role or "" == "server") null topologyList).name or null;
      incusHostName =
        (nixpkgs.lib.findFirst (n: (n.provisioner or "") == "incus-host") null topologyList).name or null;
      binaryCacheName =
        (nixpkgs.lib.findFirst (n: n.binaryCache or false) null topologyList).name or null;

      routingDependency =
        name: node:
        if (node.provisioner or "") == "incus" then
          (if incusHostName != null && incusHostName != name then incusHostName else null)
        else if node.networks ? mgmt then
          (if mgmtHubName != null && mgmtHubName != name then mgmtHubName else null)
        else
          null;

      dependsOnBinaryCache =
        name:
        binaryCacheName != null
        && name != binaryCacheName
        && name != incusHostName
        && name != mgmtHubName;

      deployDependency =
        name: node:
        if dependsOnBinaryCache name then binaryCacheName else routingDependency name node;

      deployLevel =
        name:
        let
          dep = deployDependency name deployableNodes.${name};
        in
        if dep == null then 0 else 1 + deployLevel dep;

      deployLevels = nixpkgs.lib.mapAttrs (name: _: deployLevel name) deployableNodes;
      maxDeployLevel = nixpkgs.lib.foldl' nixpkgs.lib.max 0 (nixpkgs.lib.attrValues deployLevels);
      deployPhases = map (
        l: nixpkgs.lib.attrNames (nixpkgs.lib.filterAttrs (_: lvl: lvl == l) deployLevels)
      ) (nixpkgs.lib.range 0 maxDeployLevel);

      pkgs = import nixpkgs {
        inherit system;
        inherit overlays;
      };

      # re-use deploy-rs binary from pkgs to avoid building it twice across two nixpkgs evals
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

      mkHardened = import ./modules/lib/hardening.nix { lib = nixpkgs.lib; };

      bootstrapImage = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit topology; };
        modules = [
          ./modules/profiles/bootstrap.nix
        ];
      };

      bootstrapContainerImage = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit topology; };
        modules = [
          ./modules/profiles/bootstrap-container.nix
        ];
      };

      # mutual let binding: Nix lazy eval makes this safe; hostEndpoints only forces config.homelab.endpoints
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
            incusGatewayIp = topology.nodes.${incusHostName}.networks.incus_bridge.ip;
            inherit
              lanzaboote
              authentik-nix
              hostEndpoints
              topology
              node
              mkHardened
              ;
          };
          modules = [
            sops-nix.nixosModules.sops
            quadlet-nix.nixosModules.quadlet
            decypharr.nixosModules.default
            mediafixer.nixosModules.media-fixer
            mediafixer.nixosModules.media-agent
            whitelist-sync.nixosModules.default
            {
              networking.hostName = name;
              services.media-fixer.package = mediafixer.packages.${system}.media-fixer;
              services.media-agent.package = mediafixer.packages.${system}.media-agent;
              services.minecraft-whitelist-sync.package =
                whitelist-sync.packages.${system}.minecraft-whitelist-sync;
            }
            nix-topology.nixosModules.default
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

      hostEndpoints = nixpkgs.lib.mapAttrs (_: nixos: nixos.config.homelab.endpoints) nixosConfigurations;
    in
    {
      inherit nixosConfigurations;

      topology.${system} = import nix-topology {
        inherit pkgs;
        modules = [
          ./common/nix-topology.nix
          { inherit nixosConfigurations; }
        ];
      };

      inherit deployPhases;

      deploy.nodes = builtins.mapAttrs (name: node: {
        hostname = deployHostname name node;
        inherit (node) sshUser;
        timeout = 600; # rootless podman session init can be slow on first container pull
        profiles.system = {
          user = "root";
          path = deployPkgs.deploy-rs.lib.activate.nixos self.nixosConfigurations.${name};
        };
      }) deployableNodes;

      checks = builtins.mapAttrs (_: deployLib: deployLib.deployChecks self.deploy) deploy-rs.lib;

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          just
          sops
          opentofu
          awscli2
          nix-update
          jq
          curl
          deployPkgs.deploy-rs.deploy-rs
        ];
      };

      formatter.${system} = pkgs.nixfmt-tree;

      packages.${system} = {
        inherit (pkgs) adguard-exporter;
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
