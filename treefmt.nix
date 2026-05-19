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
    # TOML formatter — covers `lychee.toml` and `_typos.toml`.
    taplo.enable = true;
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
    # breaks Material rendering. Two patterns: `docs/*.md` covers direct
    # children (e.g. dashboard.md), `docs/**/*.md` covers nested
    # (install/nix.md, etc.).
    "docs/*.md"
    "docs/**/*.md"
    # Generated, also gitignored — defense-in-depth.
    "docs/_data/dashboard.yml"
    # Test fixtures for required-checks-no-paths lint — the placeholder
    # doc uses `__SCENARIO__` which prettier rewrites to `**SCENARIO**`,
    # breaking the harness sed substitution.
    "tests/fixtures/required-checks/*"
  ];
}
