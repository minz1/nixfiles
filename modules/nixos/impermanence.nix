{ ... }:

{
  # Pre-create /persist/var/lib/private at 0700 before impermanence runs, or it resets to 0755 and breaks DynamicUser (status=238).
  # upstream: https://github.com/nix-community/impermanence/issues/254
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
