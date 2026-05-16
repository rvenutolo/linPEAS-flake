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
      # Reads [*.sh] settings from .editorconfig (binary_next_line,
      # switch_case_indent, space_redirects). When useEditorConfig is true
      # the indent_size option must be unset.
      useEditorConfig = true;
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
