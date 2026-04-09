{ config, pkgs, lib, ... }: {
  imports = [
    ./hardware-configuration.nix
  ];

  services.logrotate.checkConfig = false;

  swapDevices = [ {
    device = "/var/lib/swapfile";
    size = 4096;
  } ];

  users.users.minz1 = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHNoD5UnAh24jCiSTeS5i2WNsf7x45qYKtMEBVFVqm7C emerytang@gmail.com"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOAk9gGizgwrnA0dtN6Fv5EvQ/OyGt+d6dbtJUZUAZjZ emerytang@gmail.com"
    ];
  };

  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = true;
  networking.hostName = "minz-vultr-nix-0";
  networking.domain = "";
  users.users.root.openssh.authorizedKeys.keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHNoD5UnAh24jCiSTeS5i2WNsf7x45qYKtMEBVFVqm7C emerytang@gmail.com"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOAk9gGizgwrnA0dtN6Fv5EvQ/OyGt+d6dbtJUZUAZjZ emerytang@gmail.com"];
  system.stateVersion = "23.11";

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ ];
    allowedUDPPorts = [ 51820 ];
    trustedInterfaces = [ "wg0" ];
  };

  services.openssh = {
    enable = true;
    openFirewall = false;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
    listenAddresses = [
      {
        addr = "10.8.0.1";
        port = 22;
      }
    ];
  };

  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    dockerSocket.enable = true;
    defaultNetwork.settings.dns_enabled = true;
  };

  networking.wireguard.interfaces = {
    wg0 = {
      ips = [ "10.8.0.1/24" ];
      listenPort = 51820;

      privateKeyFile = "/var/lib/wireguard/private";

      peers = [
        {
          publicKey = "kvjC79ivkCmFXBUiJm2wt4SLoyFrlxyiZvOffSraJCc=";
          allowedIPs = [ "10.8.0.2/32" ];
        }
        {
          publicKey = "t/NvyVClqspHWixGJzjWBOnbfm4AyZNEdF9NGT1hWw4=";
          allowedIPs = [ "10.8.0.3/32" ];
        }
        {
          publicKey = "E/ptYaj0yogTCFlHuvnYV88NLErGdOL5F8p/PeW6JXM=";
          allowedIPs = [ "10.8.0.4/32" ];
        }
      ];
    };
  };

  services.forgejo = {
    enable = true;

    database.type = "postgres";

    settings = {
      server = {
        HTTP_ADDR = "10.8.0.1";
        HTTP_PORT = 3000;
        DOMAIN = "10.8.0.1";
        ROOT_URL = "http://10.8.0.1:3000/";
      };
      service = {
        DISABLE_REGISTRATION = true;
      };
    };
  };

  services.gitea-actions-runner = {
    package = pkgs.forgejo-runner;
    instances.minz_forgejo = {
      enable = true;
      name = "minz_forgejo-runner-0";
      tokenFile = "/var/lib/secrets/forgejo-runner/token";
      url = "http://10.8.0.1:3000";
      labels = [
        "ubuntu-latest:docker://catthehacker/ubuntu:act-latest"
        "node-22:docker://node:22-bookworm"
        "nixos-latest:docker://nixos/nix"
      ];
      settings = { };
    };
  };

  systemd.services."gitea-runner-minz_forgejo".serviceConfig = {
    SupplementaryGroups = [ "podman" ];
  };

  environment.systemPackages = let
    cfg = config.services.forgejo;
    forgejo-cli = pkgs.writeScriptBin "forgejo-cli" ''
      #!${pkgs.runtimeShell}
      if [[ "$USER" == "${cfg.user}" ]]; then
        export GITEA_WORK_DIR="${cfg.stateDir}"
        export GITEA_CUSTOM="${cfg.customDir}"
        cd "${cfg.stateDir}"
        exec ${pkgs.lib.getExe cfg.package} "$@"
      else
        # Bypass sudo restrictions using env and a subshell
        exec /run/wrappers/bin/sudo -u ${cfg.user} -g ${cfg.group} \
          env GITEA_WORK_DIR="${cfg.stateDir}" GITEA_CUSTOM="${cfg.customDir}" \
          ${pkgs.runtimeShell} -c 'cd "${cfg.stateDir}" && exec "$0" "$@"' \
          ${pkgs.lib.getExe cfg.package} "$@"
      fi
    '';
  in [
    forgejo-cli
  ];

  programs.neovim = {
    enable = true;
  };
}
