final: prev: {
  seerr-oidc = final.callPackage ./seerr-oidc.nix { };
  ffprobe-monitor = final.callPackage ./ffprobe-monitor { };
  adguard-exporter = final.callPackage ./adguard-exporter.nix { };
}
