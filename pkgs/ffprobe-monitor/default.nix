{
  lib,
  stdenvNoCC,
  procps,
  coreutils,
  ffmpeg,
  findutils,
  gawk,
  gnugrep,
  util-linux,
  gnused,
}:

let
  runtimePkgs = [
    procps # pgrep, ps
    coreutils # cat, sleep, date, stat, mkdir, rm, echo, timeout
    findutils # find
    gawk # awk
    ffmpeg # ffprobe
    gnugrep # grep
    util-linux # logger, renice
    gnused # sed
  ];
in
stdenvNoCC.mkDerivation {
  pname = "ffprobe-monitor";
  version = "1.0.1";

  src = ./ffprobe-monitor.sh;
  dontUnpack = true;

  binPath = lib.makeBinPath runtimePkgs;
  shell = stdenvNoCC.shell;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    substituteAll $src $out/bin/ffprobe-monitor
    chmod +x $out/bin/ffprobe-monitor

    runHook postInstall
  '';
}
