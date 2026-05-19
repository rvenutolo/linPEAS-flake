{ pkgs, ... }:
{
  projectRootFile = "flake.nix";

  programs = {
    nixfmt.enable = true;
    prettier = {
      enable = true;
      package = pkgs.nodePackages.prettier;
      # Markdown is handled by mdformat below — prettier rewraps long lines
      # and can split Jinja2 `{{ ... }}` expressions or strip admonition
      # indentation. Keep prettier for JSON/YAML only.
      includes = [
        "*.json"
        "*.yml"
        "*.yaml"
      ];
    };
    mdformat = {
      enable = true;
      # `wrap = "keep"` — never reflow paragraphs. Safest for files
      # containing Jinja2 macros (`{{ ... }}`, `{% ... %}`) consumed by
      # mkdocs-macros: line splits inside expressions break the template.
      settings.wrap = "keep";
      # `mdformat-mkdocs` bundles admonition support — adding
      # `mdformat-admon` separately causes a plugin renderer conflict that
      # sent treefmt into an infinite loop on the first batch run. Keep
      # the MkDocs plugin only.
      plugins = ps: [
        ps.mdformat-gfm
        ps.mdformat-frontmatter
        ps.mdformat-mkdocs
        ps.mdformat-footnote
      ];
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
    "*.lock"
    ".gitignore"
    ".gitattributes"
    ".editorconfig"
    ".envrc"
    "justfile"
    # Generated, also gitignored — defense-in-depth.
    "docs/_data/dashboard.yml"
    # mkdocs-macros template files — body is Jinja2, not raw markdown.
    # mdformat would treat the templating as text and corrupt control flow.
    "docs/dashboard.md"
    "docs/releases.md"
    # Contains a table cell with a Jinja2 expression inside a markdown
    # link (`[{{ x }}]({{ x }})`). mdformat-mkdocs rewrites this in a way
    # that fails the formatter's own HTML round-trip check, aborting with
    # "Could not format". Exclude until the upstream plugin handles
    # Jinja-in-link-text without escaping.
    "docs/security/trust-model.md"
    # Test fixtures for required-checks-no-paths lint — the placeholder
    # doc uses `__SCENARIO__` which formatters rewrite to `**SCENARIO**`,
    # breaking the harness sed substitution.
    "tests/fixtures/required-checks/*"
  ];
}
