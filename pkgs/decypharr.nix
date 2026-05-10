{
  buildGoModule,
  fetchFromGitHub,
  makeBinaryWrapper,
  pkg-config,
  fuse,
  fuse3,
  rclone,
  ffmpeg-headless,
  lib,
}:

buildGoModule rec {
  pname = "decypharr";
  version = "v2.2";

  src = fetchFromGitHub {
    owner = "sirrobot01";
    repo = "decypharr";
    rev = "${version}";
    hash = "sha256-Tsv6l6m+DSprcfiu2kCzKT+iHmqNLQzZdcdbL1p3aoQ=";
  };
  vendorHash = "sha256-vp74DNPJYV0HwfG4dptxOXtEaU+dnaJJYvgk0KbqkhM=";

  preCheck = ''
    echo "{}" > config.json
  '';

  checkFlags = [ "-config=config.json" ];

  nativeBuildInputs = [
    makeBinaryWrapper
    pkg-config
  ];
  buildInputs = [
    fuse
    fuse3
  ];
  postInstall = ''
    wrapProgram $out/bin/decypharr \
      --prefix PATH : ${
        lib.makeBinPath [
          rclone
          fuse3
          ffmpeg-headless
        ]
      }
  '';
}
