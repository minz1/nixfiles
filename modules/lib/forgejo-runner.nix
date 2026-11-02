{ lib }:
{
  # 16 hex chars; the runner's secret is this id followed by sops runner_token
  id = "5a69464e270e0821";
  # forgejo-cli derives the runner uuid from the hex of the id's ASCII bytes
  uuidOf =
    id:
    let
      h = lib.toLower (
        lib.concatMapStrings (c: lib.toHexString (lib.strings.charToInt c)) (lib.stringToCharacters id)
      );
    in
    lib.concatStringsSep "-" [
      (lib.substring 0 8 h)
      (lib.substring 8 4 h)
      (lib.substring 12 4 h)
      (lib.substring 16 4 h)
      (lib.substring 20 12 h)
    ];
}
