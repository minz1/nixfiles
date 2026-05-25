{ ... }:

{
  # Workaround: impermanence's createPersistentStorageDirs activation script
  # creates parent directories (including /persist/var/lib/private) with mode
  # 0755 as a side effect. systemd requires /var/lib/private to be exactly 0700
  # for DynamicUser services, and refuses to start with status=238/STATE_DIRECTORY
  # if it isn't. systemd-tmpfiles-resetup alone is insufficient because it has
  # RemainAfterExit=true and won't re-run on subsequent activations.
  #
  # Fix: pre-create /persist/var/lib/private at 0700 before createPersistentStorageDirs
  # runs, so impermanence sees it already exists and leaves the mode alone.
  #
  # Upstream bug: https://github.com/nix-community/impermanence/issues/254
  # Pattern credit: https://github.com/djacu/theonecfg/commit/26e78caa545b8124d3c9581aef7e8ebff9a9d9cd
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
