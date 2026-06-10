{
  pkgs-unstable,
  treefmtWrapper,
  ...
}:
{
  # Refuse to commit if the flake-show block in docs/reference/flake-outputs.md
  # is stale. Invokes refresh-flake-show.sh in --check mode — never mutates the
  # working tree, exits 1 on diff. Safe for the autonomous subagent
  # path (no dirty doc left behind on failure).
  flake-show-fresh = {
    enable = true;
    name = "flake-show-fresh";
    description = "flake-show block in docs/reference/flake-outputs.md matches current flake outputs.";
    entry = "${pkgs-unstable.writeShellScript "flake-show-fresh" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      # No-op when running inside a nix build sandbox — the
      # `checks.pre-commit` derivation runs all hooks, but the
      # script needs `nix flake show` which can't run inside the
      # sandbox (no daemon, restricted PATH). Local git pre-commit
      # invocation has full PATH and the check fires normally.
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then
        exit 0
      fi
      # No-op until both the script and the doc exist; the hook
      # activates once both paths are present and otherwise stays silent.
      if [[ ! -f scripts/refresh-flake-show.sh || ! -f docs/reference/flake-outputs.md ]]; then
        exit 0
      fi
      exec ${pkgs-unstable.bash}/bin/bash scripts/refresh-flake-show.sh --check
    ''}";
    files = "^(flake\\.nix|flake\\.lock|linpeas-pin\\.json|docs/reference/flake-outputs\\.md|scripts/refresh-flake-show\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  # Refuse to commit if the pre-commit hook table in docs/development/git.md
  # is stale relative to the flake hook manifest. Invokes
  # refresh-precommit-table.sh in --check mode — never mutates the
  # working tree, exits 1 on diff.
  just-recipes-fresh = {
    enable = true;
    name = "just-recipes-fresh";
    description = "just-recipes blocks in README.md and docs/reference/just-recipes.md match the justfile.";
    entry = "${pkgs-unstable.writeShellScript "just-recipes-fresh" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      export PATH="${pkgs-unstable.just}/bin:$PATH"
      exec ${pkgs-unstable.bash}/bin/bash scripts/refresh-just-recipes.sh --check
    ''}";
    files = "^(justfile|README\\.md|docs/reference/just-recipes\\.md|scripts/refresh-just-recipes\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  treefmt-config-fresh = {
    enable = true;
    name = "treefmt-config-fresh";
    description = "treefmt-config block in docs/reference/treefmt-config.md matches the evaluated treefmt config.";
    entry = "${pkgs-unstable.writeShellScript "treefmt-config-fresh" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      # No-op when running inside a nix build sandbox — the script
      # shells out to `nix eval` which can't run inside the sandbox.
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      if [[ ! -f scripts/refresh-treefmt-config.sh || ! -f docs/reference/treefmt-config.md ]]; then
        exit 0
      fi
      export PATH="${pkgs-unstable.jq}/bin:${pkgs-unstable.gawk}/bin:${treefmtWrapper}/bin:$PATH"
      exec ${pkgs-unstable.bash}/bin/bash scripts/refresh-treefmt-config.sh --check
    ''}";
    files = "^(treefmt\\.nix|flake\\.nix|flake\\.lock|docs/reference/treefmt-config\\.md|scripts/refresh-treefmt-config\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  scripts-reference-fresh = {
    enable = true;
    name = "scripts-reference-fresh";
    description = "docs/reference/scripts.md matches in-script annotations.";
    entry = "${pkgs-unstable.writeShellScript "scripts-reference-fresh" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      export PATH="${pkgs-unstable.jq}/bin:${pkgs-unstable.gawk}/bin:${treefmtWrapper}/bin:$PATH"
      exec ${pkgs-unstable.bash}/bin/bash scripts/refresh-scripts-reference.sh --check
    ''}";
    files = "^(scripts/.*\\.sh|scripts/_script_docs\\.awk|docs/reference/scripts\\.md)$";
    pass_filenames = false;
    language = "system";
  };
  precommit-table-fresh = {
    enable = true;
    name = "precommit-table-fresh";
    description = "Hook table in docs/development/git.md matches the flake hook manifest.";
    entry = "${pkgs-unstable.writeShellScript "precommit-table-fresh" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      exec ${pkgs-unstable.bash}/bin/bash scripts/refresh-precommit-table.sh --check
    ''}";
    files = "^(flake\\.nix|docs/development/git\\.md|scripts/refresh-precommit-table\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  ci-dag-fresh = {
    enable = true;
    name = "ci-dag-fresh";
    description = "docs/architecture/ci-dag.md matches .github/workflows/ci.yml needs graph.";
    entry = "${pkgs-unstable.writeShellScript "ci-dag-fresh" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      export PATH="${pkgs-unstable.jq}/bin:${pkgs-unstable.yq-go}/bin:${treefmtWrapper}/bin:$PATH"
      exec ${pkgs-unstable.bash}/bin/bash scripts/refresh-ci-dag.sh --check
    ''}";
    files = "^(\\.github/workflows/ci\\.yml|docs/_data/ci-check-categories\\.yml|docs/architecture/ci-dag\\.md|scripts/refresh-ci-dag\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  ci-summary-fresh = {
    enable = true;
    name = "ci-summary-fresh";
    description = "README CI summary matches required-checks.md and the category map.";
    entry = "${pkgs-unstable.writeShellScript "ci-summary-fresh" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      export PATH="${pkgs-unstable.yq-go}/bin:$PATH"
      exec ${pkgs-unstable.bash}/bin/bash scripts/refresh-ci-summary.sh --check
    ''}";
    files = "^(README\\.md|docs/security/required-checks\\.md|docs/_data/ci-check-categories\\.yml|scripts/refresh-ci-summary\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  enforcement-matrix-fresh = {
    enable = true;
    name = "enforcement-matrix-fresh";
    description = "docs/security/enforcement-matrix.md matches the annotated invariant index and real enforcers.";
    entry = "${pkgs-unstable.writeShellScript "enforcement-matrix-fresh" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      export PATH="${pkgs-unstable.jq}/bin:${pkgs-unstable.yq-go}/bin:$PATH"
      exec ${pkgs-unstable.bash}/bin/bash scripts/refresh-enforcement-matrix.sh --check
    ''}";
    files = "^(docs/invariant-index\\.md|docs/security/enforcement-matrix\\.md|scripts/check-.*\\.sh|scripts/refresh-enforcement-matrix\\.sh|\\.github/workflows/ci\\.yml|flake\\.nix)$";
    pass_filenames = false;
    language = "system";
  };
  # Asserts every entry in docs/invariant-index.md resolves
  # to an existing docs/ file, and every docs/**/*.md (minus
  # EXEMPT and the index itself) has an entry.
  check-orphan-invariants = {
    enable = true;
    name = "check-orphan-invariants";
    description = "Every docs/ file has an invariant-index entry and vice versa.";
    entry = "${pkgs-unstable.writeShellScript "check-orphan-invariants-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-orphan-invariants.sh
    ''}";
    files = "^(docs/invariant-index\\.md|docs/.*\\.md|scripts/check-orphan-invariants\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  # Asserts every #anchor fragment in markdown links across
  # README.md and docs/**/*.md matches a heading slug in the
  # target file (ASCII GFM/mkdocs rule).
  check-doc-anchors = {
    enable = true;
    name = "check-doc-anchors";
    description = "Every markdown #anchor link resolves to a heading slug in its target file.";
    entry = "${pkgs-unstable.writeShellScript "check-doc-anchors-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-doc-anchors.sh
    ''}";
    files = "^(README\\.md|docs/.*\\.md|scripts/check-doc-anchors\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  # Asserts the cron schedule table in docs/architecture/ci.md
  # matches cron triggers in .github/workflows/*.yml — set
  # parity, cron string accuracy, and daily arrow-list ordering
  # with strictly increasing UTC times.
  check-cron-table = {
    enable = true;
    name = "check-cron-table";
    description = "Cron schedule table + ordering paragraph in docs/architecture/ci.md matches workflow cron triggers.";
    entry = "${pkgs-unstable.writeShellScript "check-cron-table-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-cron-table.sh
    ''}";
    files = "^(\\.github/workflows/.*\\.ya?ml|docs/architecture/ci\\.md|scripts/check-cron-table\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
}
