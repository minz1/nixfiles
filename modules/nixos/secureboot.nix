{
  lib,
  pkgs,
  lanzaboote,
  ...
}:

{
  imports = [ lanzaboote.nixosModules.lanzaboote ];

  environment.systemPackages = [ pkgs.sbctl ];

  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = lib.mkForce true;

  boot.lanzaboote = {
    enable = true;
    pkiBundle = "/persist/secureboot";
    autoEnrollKeys = {
      enable = true;
      autoReboot = true;
    };
  };

  # Generate Secure Boot keys on first boot; idempotent on subsequent deploys.
  system.activationScripts.securebootKeygen = {
    text = ''
      if [ ! -f /persist/secureboot/keys/db/db.key ]; then
        echo "Generating Secure Boot keys..."
        mkdir -p /persist/secureboot/keys

        cfg=$(mktemp /tmp/sbctl-config.XXXXXX.yaml)
        cat > "$cfg" <<EOF
      landlock: false
      keydir: /persist/secureboot/keys
      guid: /persist/secureboot/GUID
      files_db: /persist/secureboot/files.json
      bundles_db: /persist/secureboot/bundles.json
      EOF

        ${pkgs.sbctl}/bin/sbctl --config "$cfg" create-keys
        chmod 600 /persist/secureboot/keys/PK/PK.key \
                  /persist/secureboot/keys/KEK/KEK.key \
                  /persist/secureboot/keys/db/db.key
        rm -f "$cfg"
      fi
    '';
  };
}
