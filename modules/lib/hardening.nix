# mkHardenedServiceConfig lib: returns a systemd serviceConfig attrset
# with standard privilege-reduction hardening. Import with:
#
#   let mkHardened = import ../lib/hardening.nix { inherit lib; }; in
#
# All parameters are named and optional; override only what differs.
{ lib }:

{
  # umask: file creation mask. "0077" for daemons that create private state.
  # Pass null to omit (e.g. when the nixpkgs module already sets one).
  umask ? "0027",
  # capabilityBoundingSet: "" drops all caps (most services).
  # Use "CAP_NET_BIND_SERVICE" for services that bind privileged ports (Caddy).
  capabilityBoundingSet ? "",
  # privateUsers: false when PrivateUsers conflicts with SupplementaryGroups
  # (DynamicUser + group membership) or with port binding via ambient caps.
  privateUsers ? true,
  # addressFamilies: AF_INET6 only needed for services that listen on IPv6.
  addressFamilies ? [
    "AF_INET"
    "AF_INET6"
    "AF_UNIX"
  ],
  # extraSystemCallFilter: additional allow entries, e.g. "@chown" or "bpf".
  extraSystemCallFilter ? [ ],
}:

(lib.optionalAttrs (umask != null) { UMask = umask; })
// {
  CapabilityBoundingSet = capabilityBoundingSet;
  NoNewPrivileges = true;
  ProtectHome = true;
  ProtectClock = true;
  ProtectKernelLogs = true;
  PrivateTmp = true;
  PrivateDevices = true;
}
// (lib.optionalAttrs privateUsers { PrivateUsers = true; })
// {
  ProtectKernelTunables = true;
  ProtectKernelModules = true;
  ProtectControlGroups = true;
  RestrictSUIDSGID = true;
  RemoveIPC = true;
  ProtectHostname = true;
  ProtectProc = "invisible";
  RestrictAddressFamilies = addressFamilies;
  RestrictNamespaces = true;
  RestrictRealtime = true;
  LockPersonality = true;
  SystemCallArchitectures = "native";
  SystemCallFilter = [
    "@system-service"
    "~@privileged"
    "~@debug"
    "~@mount"
  ]
  ++ extraSystemCallFilter;
}
