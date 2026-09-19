{ config, lib, ... }:
{
  # Pre-create /persist/var/lib/private at 0700 — impermanence resets it to 0755 otherwise, breaking DynamicUser (status=238; nix-community/impermanence#254).
  system.activationScripts."fix-var-lib-private-perms" = {
    deps = [ "specialfs" ];
    text = ''
      mkdir -p /persist/var/lib/private
      chmod 0700 /persist/var/lib/private
    '';
  };

  # ACME state: a reboot otherwise starts from minica's self-signed cert until a fresh order succeeds.
  # The seed step copies live certs in before the bind mount first hides them; no-op afterwards.
  system.activationScripts.seedPersistAcme.text = ''
    if [ ! -e /persist/var/lib/acme ] && [ -d /var/lib/acme ]; then
      mkdir -p /persist/var/lib
      cp -a /var/lib/acme /persist/var/lib/acme
    fi
  '';
  system.activationScripts."createPersistentStorageDirs".deps = [
    "fix-var-lib-private-perms"
    "seedPersistAcme"
  ];

  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/var/log"
      "/var/lib/nixos"
      "/var/lib/systemd"
      {
        directory = "/var/lib/acme";
        user = "acme";
        group = "acme";
        mode = "0755";
      }
    ]
    ++ lib.optional config.services.caddy.enable {
      directory = "/var/lib/caddy";
      user = "caddy";
      group = "caddy";
      mode = "0700";
    };
    files = [
      "/etc/machine-id"
      "/etc/ssh/ssh_host_ed25519_key"
      "/etc/ssh/ssh_host_ed25519_key.pub"
      "/etc/ssh/ssh_host_rsa_key"
      "/etc/ssh/ssh_host_rsa_key.pub"
    ];
  };
}
