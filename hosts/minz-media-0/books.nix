{
  pkgs,
  ...
}:

let
  booksReady = pkgs.writeShellApplication {
    name = "books-volume-ready";
    runtimeInputs = [
      pkgs.util-linux
      pkgs.coreutils
    ];
    text = ''
      root="''${1:-/data/books}"
      mountpoint -q "$root"
      install -d -o oci -g media -m 2775 "$root" "$root/ebooks" "$root/audiobooks"
    '';
  };
in
{
  users.users.oci.extraGroups = [ "media" ];

  systemd.tmpfiles.rules = [
    "d /data/downloads/bindery 2770 decypharr media 14d"
    "d /run/books-ready 0755 root root -"
  ];

  systemd.services.books-volume-ready = {
    description = "Check the books volume is mounted and prepare its folders";
    wantedBy = [ "multi-user.target" ];
    unitConfig.RequiresMountsFor = [ "/data/books" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${booksReady}/bin/books-volume-ready /data/books";
    };
  };
}
