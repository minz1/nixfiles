{
  pkgs,
  lib,
  fleetJson,
  deploy-rs,
  nixos-anywhere,
}:
let
  noShebang = f: lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile f);

  mkScript =
    name:
    {
      runtimeInputs ? [ ],
      bashOptions ? [
        "errexit"
        "nounset"
        "pipefail"
      ],
      runtimeEnv ? null,
    }:
    pkgs.writeShellApplication {
      inherit
        name
        runtimeInputs
        bashOptions
        runtimeEnv
        ;
      text =
        let
          body = noShebang ./${name}.sh;
        in
        lib.optionalString (lib.hasInfix "find_ram_dir" body) (noShebang ./lib.sh) + body;
    };

  noErrexit = [
    "nounset"
    "pipefail"
  ];

  p = packages;
  packages = with pkgs; {
    fleet-cli = mkScript "fleet" {
      runtimeInputs = [ jq ];
      runtimeEnv.FLEET_JSON = writeText "fleet.json" (builtins.toJSON fleetJson);
    };
    bootstrap-keygen = mkScript "bootstrap-keygen" {
      runtimeInputs = [
        coreutils
        openssh
        ssh-to-age
      ];
    };
    bootstrap-extract-key = mkScript "bootstrap-extract-key" {
      runtimeInputs = [
        coreutils
        git
        openssh
        sops
      ];
    };
    bootstrap-store-key = mkScript "bootstrap-store-key" {
      runtimeInputs = [
        coreutils
        git
        jq
        sops
      ];
    };
    bootstrap-install = mkScript "bootstrap-install" {
      runtimeInputs = [
        coreutils
        git
        nixos-anywhere
      ];
    };
    bootstrap-install-vm = mkScript "bootstrap-install-vm" {
      runtimeInputs = [
        coreutils
        git
        nixos-anywhere
        p.fleet-cli
      ];
    };
    check-secrets-encrypted = mkScript "check-secrets-encrypted" {
      runtimeInputs = [
        coreutils
        git
        gnugrep
        openssl
      ];
    };
    ci-affected-hosts = mkScript "ci-affected-hosts" {
      runtimeInputs = [
        findutils
        git
        jq
        p.fleet-cli
      ];
    };
    ci-attic-push = mkScript "ci-attic-push" {
      runtimeInputs = [
        attic-client
        coreutils
        p.fleet-cli
      ];
    };
    ci-build = mkScript "ci-build" {
      runtimeInputs = [
        coreutils
        git
        gnugrep
        p.fleet-cli
      ];
    };
    ci-flake-update = mkScript "ci-flake-update" {
      runtimeInputs = [
        p.ci-build
        p.fleet-cli
      ];
    };
    ci-vulnix = mkScript "ci-vulnix" {
      runtimeInputs = [
        coreutils
        curl
        git
        jq
        util-linux
        vulnix
        p.fleet-cli
      ];
    };
    deploy-phased = mkScript "deploy-phased" {
      bashOptions = noErrexit;
      runtimeInputs = [
        coreutils
        git
        gnugrep
        p.deploy-retry
        p.deploy-wait-healthy
        p.fleet-cli
        p.verify-attic-closure
      ];
    };
    deploy-retry = mkScript "deploy-retry" {
      runtimeInputs = [
        coreutils
        deploy-rs
        git
        p.fleet-cli
      ];
    };
    deploy-wait-healthy = mkScript "deploy-wait-healthy" {
      runtimeInputs = [
        coreutils
        p.fleet-cli
      ];
    };
    health-check = mkScript "health-check" {
      bashOptions = noErrexit;
      runtimeInputs = [
        gnugrep
        p.fleet-cli
      ];
    };
    reboot-fleet = mkScript "reboot-fleet" {
      bashOptions = noErrexit;
      runtimeInputs = [
        coreutils
        p.deploy-wait-healthy
        p.fleet-cli
      ];
    };
    tofu-destroy-host = mkScript "tofu-destroy-host" {
      runtimeInputs = [
        git
        jq
        p.with-incus
      ];
    };
    tofu-publish-image = mkScript "tofu-publish-image" {
      runtimeInputs = [
        awscli2
        coreutils
        git
        sops
      ];
    };
    verify-attic-closure = mkScript "verify-attic-closure" {
      runtimeInputs = [
        curl
        git
        gnugrep
        jq
        p.fleet-cli
      ];
    };
    with-incus = mkScript "with-incus" {
      runtimeInputs = [
        coreutils
        git
        opentofu
        sops
      ];
    };
  };
in
{
  inherit packages;

  checks = {
    script-tests =
      pkgs.runCommand "script-tests"
        {
          nativeBuildInputs = with pkgs; [
            age
            coreutils
            git
            gnugrep
            gnused
            jq
            sops
            busybox
          ];
        }
        ''
          cp -r ${./.} scripts
          chmod -R u+w scripts
          patchShebangs scripts
          cd scripts
          bash fleet.test.sh
          bash ci-affected-hosts.test.sh
          bash deploy-phased.test.sh
          bash secrets-copy.test.sh
          bash router/adguard-querylog.test.sh
          touch $out
        '';

    shellcheck = pkgs.runCommand "scripts-shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
      cd ${./.}
      shellcheck -x -P . ./*.test.sh secrets-copy.sh secrets-same.sh
      cd router
      shellcheck -s sh adguard-querylog
      shellcheck -x ./*.sh
      touch $out
    '';
  };
}
