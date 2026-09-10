{
  lib,
  hostName,
  hostEndpoints,
  ...
}:

let
  topology = import ../../common/topology.nix;
  attic = (hostEndpoints."minz-attic-0" or { }).attic or null;
  isGuest = (topology.nodes.${hostName}.provisioner or "") == "incus";
  atticUrl = "https://minz-attic-0.internal/homelab";
  atticKeys = [ "homelab:/832u4B/jZREiimqBzchHGyXQZaUVKoG4TlO/nUJh10=" ];
  applies = attic != null && hostName != "minz-attic-0";
in
lib.mkMerge [
  # guests can't reach cache.nixos.org (ACL default-reject) — stay forced empty until Attic exists.
  (lib.mkIf isGuest {
    nix.settings.substituters = lib.mkForce (lib.optional applies atticUrl);
    nix.settings.trusted-public-keys = lib.mkIf applies atticKeys;
  })
  # extra-substituters would render before this and get silently discarded; mkBefore instead.
  (lib.mkIf (!isGuest && applies) {
    nix.settings.substituters = lib.mkBefore [ atticUrl ];
    nix.settings.trusted-public-keys = atticKeys;
  })
]
