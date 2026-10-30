{
  lib,
  hostName,
  topology,
  fleet,
  ...
}:

let
  isGuest = fleet.isGuest topology.nodes.${hostName};
  atticUrl = "https://${topology.services.attic.host}.internal/homelab";
  atticKeys = [ "homelab:/832u4B/jZREiimqBzchHGyXQZaUVKoG4TlO/nUJh10=" ];
  applies = topology.services ? attic && topology.services.attic.host != hostName;
  # ci-runner nodes get the runner incus_network_acl (tofu/infra/acls.tf), which grants full HTTP/HTTPS
  # egress for nix builds, unlike other Incus guests (default-reject) — safe to also use
  # cache.nixos.org as a substituter fallback here, the network access already exists.
  restrictToAttic = isGuest && !lib.elem "ci-runner" topology.nodes.${hostName}.roles;
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
