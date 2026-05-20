{
  pkgs,
  hostName,
  ...
}:

let
  topology = import ../common/topology.nix;
  node = topology.nodes.${hostName} or (throw "No topology entry for ${hostName}");
  vmIp = node.networks.incus_bridge.ip;
in
{
  networking.hostName = hostName;

  networking.useNetworkd = true;
  networking.useDHCP = false;

  systemd.network.networks."10-enp" = {
    matchConfig.Name = "en*";
    networkConfig.Address = [ "${vmIp}/24" ];
    networkConfig.Gateway = [ "10.10.0.1" ];
    linkConfig.RequiredForOnline = "routable";
  };

  services.openssh.listenAddresses = [
    {
      addr = "0.0.0.0";
      port = 22;
    }
  ];
  systemd.services.sshd.after = [ ];
  systemd.services.sshd.wants = [ ];

  networking.firewall.allowedTCPPorts = [ 22 ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = false;

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
  };

  fileSystems."/persist" = {
    device = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_incus_persist";
    fsType = "ext4";
    neededForBoot = false;
  };

  # ── Automation ───────────────────────────────────────────────────
  # Format the persistent disk on first boot if it's currently unformatted.
  # This runs during every activation but only executes mkfs if blkid fails.
  system.activationScripts.formatPersist = ''
    DISK="/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_incus_persist"
    if [ -b "$DISK" ] && ! ${pkgs.e2fsprogs}/bin/blkid "$DISK" >/dev/null; then
      echo "base-vm: formatting $DISK as ext4 (label: persist)"
      ${pkgs.e2fsprogs}/bin/mkfs.ext4 -L persist "$DISK"
    fi
  '';
}
