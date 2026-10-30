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
      lib = nixpkgs.lib;
      fleet = import ./common/fleet {
        inherit lib;
        topology = import ./common/topology.nix;
        services = ./common/services.nix;
        hostDirs = builtins.attrNames (lib.filterAttrs (_: t: t == "directory") (builtins.readDir ./hosts));
      };
      topology = { inherit (fleet) networks nodes services; };
      fleetArgs = { inherit (fleet) addressOf isGuest; };
      inherit (fleet) isGuest;

      overlays = [
        overlay
        nix-topology.overlays.default
      ];

      nixosNodes = nixpkgs.lib.filterAttrs (_: n: n.kind != "device") topology.nodes;

      configurableNodes = nixpkgs.lib.filterAttrs (_: n: n.hasConfig) nixosNodes;

      deployHostname = name: _: fleet.addressOf "minz-desktop" name;

      deployableNodes = configurableNodes;

      # Dependency-ordered deploy phases, derived from the routing topology
      topologyList = nixpkgs.lib.attrValues topology.nodes;
      mgmtHubName =
        (nixpkgs.lib.findFirst (n: n.networks.mgmt.role or "" == "server") null topologyList).name or null;
      incusHostName = (nixpkgs.lib.findFirst (n: n.kind == "incus-host") null topologyList).name or null;
      binaryCacheName = (nixpkgs.lib.findFirst (n: n.binaryCache) null topologyList).name or null;

      routingDependency =
        name: node:
        if isGuest node then
          (if incusHostName != null && incusHostName != name then incusHostName else null)
        else if node.networks ? mgmt then
          (if mgmtHubName != null && mgmtHubName != name then mgmtHubName else null)
        else
          null;

      dependsOnBinaryCache =
        name:
        binaryCacheName != null && name != binaryCacheName && name != incusHostName && name != mgmtHubName;

      deployDependency =
        name: node: if dependsOnBinaryCache name then binaryCacheName else routingDependency name node;

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

      fleetJson = {
        inherit (fleet) nodes;
        phases = deployPhases;
        addresses = lib.filterAttrs (_: a: a != null) (
          builtins.mapAttrs (name: _: fleet.addressOf "minz-desktop" name) fleet.nodes
        );
        targets = builtins.mapAttrs (
          name: node: "${node.sshUser}@${deployHostname name node}"
        ) deployableNodes;
      };

      scripts = import ./scripts {
        inherit pkgs lib fleetJson;
        deploy-rs = deployPkgs.deploy-rs.deploy-rs;
        nixos-anywhere = nixos-anywhere.packages.${system}.nixos-anywhere;
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
        specialArgs = {
          inherit topology;
          fleet = fleetArgs;
        };
        modules = [
          ./modules/profiles/bootstrap.nix
        ];
      };

      bootstrapContainerImage = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          inherit topology;
          fleet = fleetArgs;
        };
        modules = [
          ./modules/profiles/bootstrap-container.nix
        ];
      };

      nixosConfigurations = builtins.mapAttrs (
        name: node:
        let
          isContainer = node.kind == "incus-container";
          isVm = node.kind == "incus-vm";
          isBareMetal = node.kind == "vps" || node.kind == "incus-host";
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
            fleet = fleetArgs;
            endpoints = fleet.endpointsFor name;
            inherit
              lanzaboote
              authentik-nix
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

      fleet = fleetJson;

      checks.${system} =
        scripts.packages
        // scripts.checks
        // (
          let
            t = import ./common/fleet/tests.nix {
              inherit lib;
              mkFleet = import ./common/fleet;
            };
            passedNegatives = builtins.filter (n: !n.failed) t.negative;
          in
          {
            fleet-unit = pkgs.runCommand "fleet-unit" { } (
              if t.unit == [ ] && t.positive then
                "touch $out"
              else
                throw "fleet unit tests failed: ${builtins.toJSON t.unit}, base fixture evaluates: ${lib.boolToString t.positive}"
            );
            fleet-output = pkgs.runCommand "fleet-output" { } (
              if self.packages.${system} ? fleet then
                throw "packages.fleet shadows the fleet data output"
              else
                "touch $out"
            );
            fleet-negative = pkgs.runCommand "fleet-negative" { } (
              if passedNegatives == [ ] then
                "touch $out"
              else
                throw "fleet fixtures that should fail evaluated cleanly: ${
                  lib.concatMapStringsSep ", " (n: n.name) passedNegatives
                }"
            );
          }
        );

      deploy.nodes = builtins.mapAttrs (name: node: {
        hostname = deployHostname name node;
        inherit (node) sshUser;
        timeout = 600; # rootless podman session init can be slow on first container pull
        profiles.system = {
          user = "root";
          path = deployPkgs.deploy-rs.lib.activate.nixos self.nixosConfigurations.${name};
        };
      }) deployableNodes;

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          just
          sops
          opentofu
          awscli2
          jq
          curl
          ssh-to-age
          shellcheck
          age
          openssl
          deployPkgs.deploy-rs.deploy-rs
        ];
      };

      formatter.${system} = pkgs.nixfmt-tree;

      packages.${system} = scripts.packages // {
        inherit (pkgs) adguard-exporter;
        kexec-installer =
          nixos-anywhere.inputs.nixos-images.packages.${system}.kexec-installer-nixos-unstable-noninteractive;
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
