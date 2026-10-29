{ lib, hostDirs }:
{ config, ... }:
let
  inherit (lib) mkOption types;
  optStr = mkOption {
    type = types.nullOr types.str;
    default = null;
  };
  optInt =
    description:
    mkOption {
      type = types.nullOr types.int;
      default = null;
      inherit description;
    };
  flag = mkOption {
    type = types.bool;
    default = false;
  };

  network = types.submodule {
    options = {
      type = mkOption {
        type = types.enum [
          "wireguard"
          "incus"
        ];
      };
      subnet = mkOption { type = types.str; };
      interface = mkOption { type = types.str; };
      listenPort = mkOption {
        type = types.nullOr types.port;
        default = null;
      };
    };
  };

  membership = types.submodule {
    options = {
      ip = mkOption { type = types.str; };
      role = mkOption {
        type = types.nullOr (
          types.enum [
            "server"
            "client"
            "gateway"
          ]
        );
        default = null;
      };
      publicKey = optStr;
      endpoint = optStr;
      extraAllowedIPs = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
    };
  };

  storage = types.submodule {
    options = {
      disk = mkOption { type = types.str; };
      nix_gib = mkOption {
        type = types.int;
        description = "Size of the /nix partition in GiB.";
      };
      rustfs_disk = optStr;
      incus_disk = optStr;
    };
  };

  incus = types.submodule {
    options = {
      cpus = mkOption { type = types.int; };
      memory_gib = mkOption {
        type = types.int;
        description = "Memory limit in GiB.";
      };
      nix_gib = optInt "Size of the /nix partition in GiB (incus-vm).";
      total_gib = optInt "Size of the whole data disk in GiB; /persist gets what /nix leaves (incus-vm).";
      root_gib = optInt "Root disk size in GiB (incus-container).";
      gpu = flag;
      nesting = flag;
    };
  };

  node = types.submodule (
    { name, ... }:
    {
      options = {
        name = mkOption {
          type = types.str;
          default = name;
          readOnly = true;
        };
        kind = mkOption {
          type = types.enum [
            "vps"
            "incus-host"
            "incus-vm"
            "incus-container"
            "device"
          ];
        };
        sshUser = mkOption {
          type = types.str;
          default = "minz1";
        };
        binaryCache = flag;
        hasConfig = mkOption {
          type = types.bool;
          default = builtins.elem name hostDirs;
          readOnly = true;
        };
        storage = mkOption {
          type = types.nullOr storage;
          default = null;
        };
        incus = mkOption {
          type = types.nullOr incus;
          default = null;
        };
        networks = mkOption {
          type = types.attrsOf membership;
          default = { };
        };
      };
    }
  );

  service = types.submodule {
    options = {
      host = mkOption { type = types.enum (builtins.attrNames config.nodes); };
      port = mkOption { type = types.port; };
    };
  };
in
{
  options = {
    networks = mkOption { type = types.attrsOf network; };
    nodes = mkOption { type = types.attrsOf node; };
    services = mkOption {
      type = types.attrsOf service;
      default = { };
    };
  };
}
