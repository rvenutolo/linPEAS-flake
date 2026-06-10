{
  pkgs-unstable,
  actionlintWrapped,
  treefmtWrapper,
  ...
}:
{
  actionlint = {
    enable = true;
    description = "GitHub Actions workflow syntax (shellcheck pinned).";
    entry = "${actionlintWrapped}/bin/actionlint";
  };
  # Doc-quality hooks — mirror the CI lint required-check set
  # so author catches issues before push.
  markdownlint = {
    enable = true;
    description = "Markdown style + structure.";
    # Excludes mirror the CI markdownlint-cli2-action globs:
    # docs/dashboard.md + docs/releases.md are mkdocs-macros
    # templated and not raw markdown; docs/_data/* is the
    # generated dashboard YAML. tests/fixtures/* contains
    # intentionally-invalid markdown for test harnesses.
    excludes = [
      "^docs/dashboard\\.md$"
      "^docs/releases\\.md$"
      "^docs/_data/"
      "^tests/fixtures/"
      # Generator-owned by git-cliff; rule violations there
      # come from cliff's template, not author choice.
      "^CHANGELOG\\.md$"
    ];
  };
  typos = {
    enable = true;
    description = "Spell-check across the repo.";
  };
  editorconfig-checker = {
    enable = true;
    description = ".editorconfig compliance (charset, line endings, trailing whitespace, final newline).";
  };
  # Conventional Commits enforcement: `commitlint` with the
  # `@commitlint/config-conventional` ruleset from
  # `.commitlintrc.yml`. Parity with the CI `commitlint` job —
  # same engine, same config, so any rule (subject type-enum,
  # body-max-line-length, header-max-length, etc.) fails
  # locally instead of after push. Replaces the older
  # `commitizen.enable` hook, which validated the subject only.
  commitlint = {
    enable = true;
    name = "commitlint";
    description = "Commit message satisfies Conventional Commits (CI parity via .commitlintrc.yml).";
    entry = "${pkgs-unstable.commitlint}/bin/commitlint --config .commitlintrc.yml --edit";
    stages = [ "commit-msg" ];
    language = "system";
    pass_filenames = true;
  };
  zizmor = {
    enable = true;
    description = "GitHub Actions security audit.";
    # Older zizmor versions (e.g. 1.8.0 from nixos-25.05) exit
    # non-zero on any finding including informational. Newer
    # versions default to `--min-severity=low`; mirror that
    # here so the hook is consistent across nixpkgs bumps.
    entry = "${pkgs-unstable.zizmor}/bin/zizmor --min-severity=low";
  };
  octoscan = {
    enable = true;
    description = "synacktiv/octoscan workflow vulnerability scanner.";
    # Digest + version pinned in scripts/octoscan-scan.sh.
    # Renovate's customManager is scoped to that script.
    # Hook always scans the full .github/workflows directory
    # to match the CI workflow's invocation; trigger is
    # restricted to workflow yaml changes via `files`.
    entry = "${pkgs-unstable.writeShellScript "octoscan-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      # Skip inside nix build sandbox — docker is unavailable
      # and the script would fail. The local pre-commit invocation
      # has full PATH and the hook fires normally.
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      exec ${pkgs-unstable.bash}/bin/bash scripts/octoscan-scan.sh
    ''}";
    files = "^\\.github/workflows/.*\\.ya?ml$";
    pass_filenames = false;
    language = "system";
  };
  yamllint = {
    enable = true;
    description = "YAML style.";
  };
  shellcheck = {
    enable = true;
    description = "Shell-script static analysis.";
    # justfile is parsed by `just`, not bash; shellcheck
    # misidentifies it as shell because the first line looks
    # like a comment.
    excludes = [ "^justfile$" ];
  };
  treefmt = {
    enable = true;
    description = "Multi-language formatter aggregator (shfmt, prettier, etc).";
    package = treefmtWrapper;
  };
  # Schema-shape validation for repo config. Catches typoed
  # keys, wrong-type values, and upstream-removed fields that
  # per-tool linters miss. NIX_BUILD_TOP guard skips inside
  # the flake-check sandbox where network fetches for the
  # pinned SchemaStore schema would fail.
  check-jsonschema = {
    enable = true;
    name = "check-jsonschema";
    description = "Schema-shape validation of repo config (renovate.json, workflows, actions).";
    entry = "${pkgs-unstable.writeShellScript "check-jsonschema-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      export PATH="${pkgs-unstable.check-jsonschema}/bin:$PATH"
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-jsonschema.sh
    ''}";
    files = "^(renovate\\.json|\\.markdownlint\\.json|\\.github/workflows/.*\\.ya?ml|\\.github/actions/.*\\.ya?ml|scripts/check-jsonschema\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  # Validates renovate.json against the upstream Renovate
  # config schema. Catches typoed keys / wrong-type values
  # before they ship and surface as a Dependency Dashboard
  # error after merge. NIX_BUILD_TOP guard skips inside the
  # flake-check sandbox where the validator's network probes
  # would fail.
  renovate-config-validator = {
    enable = true;
    name = "renovate-config-validator";
    description = "Validate renovate.json against the upstream Renovate config schema.";
    entry = "${pkgs-unstable.writeShellScript "renovate-config-validator-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      export PATH="${pkgs-unstable.renovate}/bin:$PATH"
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-renovate-config-validator.sh
    ''}";
    files = "^(renovate\\.json|scripts/check-renovate-config-validator\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
}
