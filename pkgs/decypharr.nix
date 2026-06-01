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
  version = "2.3";

  src = fetchFromGitHub {
    owner = "sirrobot01";
    repo = "decypharr";
    rev = "v${version}";
    hash = "sha256-Ms8FjpxasogWP/H/pAa5SZ/DgHoLcRyC5hjIpvuJ2BU=";
  };
  vendorHash = "sha256-Pl21UNO5Oe2rILB2SDS99pyR5Q6gi0BplTTnCVKkWZM=";

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
      --prefix PATH : /run/wrappers/bin \
      --suffix PATH : ${
        lib.makeBinPath [
          rclone
          ffmpeg-headless
        ]
      }
  '';
}
