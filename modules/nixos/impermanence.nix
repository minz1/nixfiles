{
  # Pre-create /persist/var/lib/private at 0700 — impermanence resets it to 0755 otherwise, breaking DynamicUser (status=238; nix-community/impermanence#254).
  system.activationScripts."createPersistentStorageDirs".deps = [ "fix-var-lib-private-perms" ];
  system.activationScripts."fix-var-lib-private-perms" = {
    deps = [ "specialfs" ];
    text = ''
      mkdir -p /persist/var/lib/private
      chmod 0700 /persist/var/lib/private
    '';
  };

  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/var/log"
      "/var/lib/nixos"
      "/var/lib/systemd"
    ];
    files = [
      "/etc/machine-id"
      "/etc/ssh/ssh_host_ed25519_key"
      "/etc/ssh/ssh_host_ed25519_key.pub"
      "/etc/ssh/ssh_host_rsa_key"
      "/etc/ssh/ssh_host_rsa_key.pub"
    ];
  };
}
