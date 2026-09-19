{
  writeShellApplication,
  procps,
  coreutils,
  findutils,
  ffmpeg,
  util-linux,
}:

writeShellApplication {
  name = "ffprobe-monitor";
  runtimeInputs = [
    procps # ps
    coreutils # date, md5sum, cut, cat, timeout, sleep
    findutils
    ffmpeg # ffprobe
    util-linux # logger
  ];
  text = builtins.readFile ./ffprobe-monitor.sh;
}
