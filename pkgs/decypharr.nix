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
  version = "1.1.7-minz";

  src = fetchFromGitHub {
    owner = "minz1";
    repo = "decypharr";
    rev = "${version}";
    hash = "sha256-b1KBUv32Y2b0o7dpuk6XgYvwRCTGqYuejTYi6NP15xw";
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
