{
  projectRootFile = "flake.nix";
  programs.nixfmt.enable = true;
  programs.shfmt = {
    enable = true;
    indent_size = 4;
    simplify = false;
  };
  settings.formatter.shfmt.options = [
    "-ci"
    "-sr"
    "-bn"
  ];
  programs.terraform.enable = true;
  programs.yamlfmt = {
    enable = true;
    settings.formatter = {
      retain_line_breaks_single = true;
      pad_line_comments = 2;
    };
  };
  settings.global.excludes = [
    "secrets/**"
    ".sops.yaml"
    "config/prowlarr/indexers/**"
  ];
}
