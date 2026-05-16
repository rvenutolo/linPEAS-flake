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
    # Pages site: Jinja2 macros in markdown — prettier rewrap can split
    # `{{ ... }}` expressions across lines and break macro expansion, and
    # also strips indentation inside `!!! admonition` bodies which silently
    # breaks Material rendering.
    "docs/**/*.md"
    # Generated, also gitignored — defense-in-depth.
    "docs/_data/dashboard.yml"
  ];
}
