{ lib }:

{
  umask ? "0027",
  capabilityBoundingSet ? "",
  # needed alongside capabilityBoundingSet for units with an explicit User= (even root)
  ambientCapabilities ? "",
  privateUsers ? true,
  addressFamilies ? [
    "AF_INET"
    "AF_INET6"
    "AF_UNIX"
  ],
  extraSystemCallFilter ? [ ],
}:

(lib.optionalAttrs (umask != null) { UMask = umask; })
// {
  CapabilityBoundingSet = capabilityBoundingSet;
  AmbientCapabilities = ambientCapabilities;
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
