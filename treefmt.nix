{ pkgs, ... }:
{
  projectRootFile = "flake.nix";

  programs = {
    nixpkgs-fmt.enable = true;
    prettier = {
      enable = true;
      package = pkgs.nodePackages.prettier;
      includes = [ "*.json" "*.md" "*.yml" "*.yaml" ];
    };
    shfmt = {
      enable = true;
      indent_size = 2;
    };
  };

  settings.global.excludes = [
    "LICENSE"
    "README.md"
    "*.lock"
    ".gitignore"
    ".gitattributes"
    ".editorconfig"
    ".envrc"
    "justfile"
  ];
}
