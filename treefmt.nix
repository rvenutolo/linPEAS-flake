{ lib, pkgs, ... }:
{
  projectRootFile = "flake.nix";

  programs = {
    nixfmt.enable = true;
    prettier = {
      enable = true;
      package = pkgs.prettier;
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
        # Auto-regenerates TOC between
        # `<!-- mdformat-toc start -->` / `<!-- mdformat-toc end -->`
        # markers. No-op on files without markers; opt-in per file.
        # Convention documented in docs/development/linting.md.
        ps.mdformat-toc
      ];
    };
    shfmt = {
      enable = true;
      indent_size = 2;
      # Default shfmt glob `*.envrc` does not match the literal `.envrc`
      # filename. Add it explicitly so direnv hooks are formatted.
      includes = [
        "*.sh"
        "*.bash"
        "*.envrc"
        "*.envrc.*"
        ".envrc"
      ];
    };
    # `just --fmt --unstable --indentation 2` formats the top-level
    # `justfile` to match the repo-wide 2-space convention.
    just = {
      enable = true;
    };
    # TOML formatter — covers `lychee.toml` and `_typos.toml`.
    taplo.enable = true;
  };

  # The treefmt-nix `just` module does not expose `indent_size`, so
  # override the bash-wrapper options to pass `--indentation 2`.
  settings.formatter.just.options = lib.mkForce [
    "-euc"
    ''
      for f in "$@"; do
        ${lib.getExe pkgs.just} --fmt --unstable --indentation "  " --justfile "$f"
      done
    ''
    "--"
  ];

  settings.global.excludes = [
    "LICENSE"
    "*.lock"
    ".gitignore"
    ".gitattributes"
    ".editorconfig"
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
    # Generator-owned changelog. mdformat re-escapes characters that
    # git-cliff renders verbatim, causing a write-back loop between the
    # release-on-bump `changelog` job and any local treefmt run.
    "CHANGELOG.md"
    # renovate-config-validator bad-syntax fixture is intentionally
    # malformed JSON to exercise the parse-error branch of the validator;
    # prettier refuses to format invalid JSON.
    "tests/fixtures/check-renovate-config-validator/bad-syntax.json"
    # scorecard-threshold malformed fixture is intentionally invalid
    # JSON to exercise the parse-error branch of the threshold check;
    # prettier refuses to format invalid JSON.
    "tests/fixtures/scorecard-threshold/malformed.json"
    # `bad-malformed.yml` fixtures are intentionally unparsable YAML that
    # exercise the parse-failure branch of the workflow-lint checks;
    # prettier refuses to format invalid YAML.
    "tests/fixtures/harden-runner-first/bad-malformed.yml"
    "tests/fixtures/job-timeout-minutes/bad-malformed.yml"
    "tests/fixtures/run-block-strict/bad-malformed.yml"
    "tests/fixtures/setup-nix-required/bad-malformed.yml"
    "tests/fixtures/upload-artifact-strict/bad-malformed.yml"
  ];
}
