{ pkgs, lib, ... }:

let
  vars = import ./vars.nix;

  decypharr-pkg = pkgs.buildGoModule rec {
    pname = "decypharr";
    version = "1.1.7-minz";

    src = pkgs.fetchFromGitHub {
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

    nativeBuildInputs = [ pkgs.makeBinaryWrapper pkgs.pkg-config ];
    buildInputs = [ pkgs.fuse pkgs.fuse3 ];
    postInstall = ''
      wrapProgram $out/bin/decypharr \
        --prefix PATH : ${lib.makeBinPath [ pkgs.rclone pkgs.fuse3 pkgs.ffmpeg-headless ]}
    '';

  };
in
{
  networking.firewall.allowedTCPPorts = [ 8282 ];

  programs.fuse.userAllowOther = true;

  users.users.decypharr = {
    isSystemUser = true;
    group = "decypharr";
    extraGroups = [ vars.mediaGroup ];
  };
  users.groups.decypharr = {};

  systemd.services.decypharr = {
    description = "Decypharr - Debrid Mock QBittorrent";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      ExecStart = "${decypharr-pkg}/bin/decypharr --config /var/lib/decypharr";

      User = "decypharr";
      Group = "decypharr";
      WorkingDirectory = "/var/lib/decypharr";
      Restart = "on-failure";
      RestartSec = 5;

      ReadWritePaths = [ vars.mediaPath ];

      CapabilityBoundingSet = [ "CAP_SYS_ADMIN" ];
      AmbientCapabilities = [ "CAP_SYS_ADMIN" ];
      DeviceAllow = [ "/dev/fuse rw" ];
      PrivateDevices = false;

      NoNewPrivileges = true;
      ProtectSystem = "strict";
      PrivateTmp = true;
      StateDirectory = "decypharr";
    };
  };
}
