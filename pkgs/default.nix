final: prev: {
  decypharr = final.callPackage ./decypharr.nix { };
  seerr-oidc = final.callPackage ./seerr-oidc.nix { };
}
