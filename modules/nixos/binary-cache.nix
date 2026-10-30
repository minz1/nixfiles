{
  lib,
  hostName,
  topology,
  fleet,
  ...
}:

let
  isGuest = fleet.isGuest topology.nodes.${hostName};
  atticUrl = "https://minz-attic-0.internal/homelab";
  atticKeys = [ "homelab:/832u4B/jZREiimqBzchHGyXQZaUVKoG4TlO/nUJh10=" ];
  applies = topology.services ? attic && topology.services.attic.host != hostName;
  # minz-runner-0's incus_network_acl (tofu/infra/acls.tf) explicitly grants full HTTP/HTTPS
  # egress for nix builds, unlike other Incus guests (default-reject) — safe to also use
  # cache.nixos.org as a substituter fallback here, the network access already exists.
  restrictToAttic = isGuest && hostName != "minz-runner-0";
in
lib.mkMerge [
  (lib.mkIf restrictToAttic {
    nix.settings.substituters = lib.mkForce (lib.optional applies atticUrl);
    nix.settings.trusted-public-keys = lib.mkIf applies atticKeys;
  })
  # extra-substituters would render before this and get silently discarded; mkBefore instead.
  (lib.mkIf (!restrictToAttic && applies) {
    nix.settings.substituters = lib.mkBefore [ atticUrl ];
    nix.settings.trusted-public-keys = atticKeys;
  })
]
