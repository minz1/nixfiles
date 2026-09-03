final: _prev: {
  ffprobe-monitor = final.callPackage ./ffprobe-monitor { };
  adguard-exporter = final.callPackage ./adguard-exporter.nix { };
}
