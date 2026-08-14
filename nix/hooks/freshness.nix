{
  pkgs-unstable,
  treefmtWrapper,
  ...
}:
let
  # Union of every hard requirement the scripts/ generators behind these
  # hooks declare with `require_tool`, exported by every hook in this file
  # rather than per-hook subsets. One shared prelude means a generator that
  # adds a `require_tool` needs no hook edit here, and a commit made from a
  # shell outside the devShell resolves the same pinned binaries the
  # devShell does instead of whatever the host happens to ship.
  #
  # `git` and `nix` stay ambient on purpose: the hooks run under the user's
  # git, and pinning nix inside a hook would shadow the host daemon client.
  #
  # treefmt must be the store-baked wrapper. The generators format the doc
  # they compare against, so an ambient treefmt — different formatter
  # versions, none of this repo's baked config — makes `--check` report
  # drift that is not there or pass a doc that is stale.
  #
  # `shfmt` is listed in its own right even though the treefmt wrapper also
  # carries one: the wrapper reaches its formatters internally, so a script
  # invoking `shfmt` as a bare command — the ephemeral-reference lint reads
  # shell comments out of `shfmt --to-json` — resolves nothing without this
  # entry.
  toolPath = pkgs-unstable.lib.makeBinPath [
    pkgs-unstable.coreutils
    pkgs-unstable.diffutils
    pkgs-unstable.gawk
    pkgs-unstable.gnugrep
    pkgs-unstable.gnused
    pkgs-unstable.jq
    pkgs-unstable.just
    pkgs-unstable.shfmt
    pkgs-unstable.yq-go
    treefmtWrapper
  ];
in
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
      export PATH="${toolPath}:$PATH"
      exec ${pkgs-unstable.bash}/bin/bash scripts/refresh-flake-show.sh --check
    ''}";
    files = "^(flake\\.nix|flake\\.lock|linpeas-pin\\.json|nix/.*\\.nix|docs/reference/flake-outputs\\.md|scripts/refresh-flake-show\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  # Refuse to commit if the just-recipes blocks in README.md and
  # docs/reference/just-recipes.md are stale relative to the justfile.
  # Invokes refresh-just-recipes.sh in --check mode — never mutates the
  # working tree, exits 1 on diff.
  just-recipes-fresh = {
    enable = true;
    name = "just-recipes-fresh";
    description = "just-recipes blocks in README.md and docs/reference/just-recipes.md match the justfile.";
    entry = "${pkgs-unstable.writeShellScript "just-recipes-fresh" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      export PATH="${toolPath}:$PATH"
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
      export PATH="${toolPath}:$PATH"
      exec ${pkgs-unstable.bash}/bin/bash scripts/refresh-treefmt-config.sh --check
    ''}";
    files = "^(treefmt\\.nix|flake\\.nix|flake\\.lock|nix/.*\\.nix|docs/reference/treefmt-config\\.md|scripts/refresh-treefmt-config\\.sh)$";
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
      export PATH="${toolPath}:$PATH"
      exec ${pkgs-unstable.bash}/bin/bash scripts/refresh-scripts-reference.sh --check
    ''}";
    files = "^(scripts/.*\\.sh|scripts/_script_docs\\.awk|docs/reference/scripts\\.md)$";
    pass_filenames = false;
    language = "system";
  };
  # Refuse to commit if the pre-commit hook table in docs/development/git.md
  # is stale relative to the flake hook manifest. Invokes
  # refresh-precommit-table.sh in --check mode — never mutates the
  # working tree, exits 1 on diff.
  precommit-table-fresh = {
    enable = true;
    name = "precommit-table-fresh";
    description = "Hook table in docs/development/git.md matches the flake hook manifest.";
    entry = "${pkgs-unstable.writeShellScript "precommit-table-fresh" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      export PATH="${toolPath}:$PATH"
      exec ${pkgs-unstable.bash}/bin/bash scripts/refresh-precommit-table.sh --check
    ''}";
    files = "^(flake\\.nix|nix/hooks/.*\\.nix|nix/manifests\\.nix|docs/development/git\\.md|scripts/refresh-precommit-table\\.sh)$";
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
      export PATH="${toolPath}:$PATH"
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
      export PATH="${toolPath}:$PATH"
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
      export PATH="${toolPath}:$PATH"
      exec ${pkgs-unstable.bash}/bin/bash scripts/refresh-enforcement-matrix.sh --check
    ''}";
    files = "^(docs/invariant-index\\.md|docs/security/enforcement-matrix\\.md|scripts/check-.*\\.sh|scripts/refresh-enforcement-matrix\\.sh|\\.github/workflows/ci\\.yml|flake\\.nix|nix/hooks/.*\\.nix|nix/manifests\\.nix)$";
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
      export PATH="${toolPath}:$PATH"
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
      export PATH="${toolPath}:$PATH"
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-doc-anchors.sh
    ''}";
    files = "^(README\\.md|docs/.*\\.md|scripts/check-doc-anchors\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  # Asserts Markdown prose and the comments in every shell, Nix and
  # YAML source carry no ephemeral references (PR/issue refs, prose
  # dates, planning/review-pass labels, literal `.claude/` paths). Shell
  # comments are lifted from the `shfmt` syntax tree, which is why
  # `shfmt` is on the shared tool path. Runs the blocking pass first
  # (gates the commit), then the --advisory pass for fuzzy
  # causal-history phrases (never gates — always exits 0).
  check-ephemeral-refs = {
    enable = true;
    name = "check-ephemeral-refs";
    description = "Markdown prose and shell/Nix/YAML comments carry no ephemeral references (PR/issue refs, prose dates, planning/review labels, literal .claude/ paths).";
    entry = "${pkgs-unstable.writeShellScript "check-ephemeral-refs-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      export PATH="${toolPath}:$PATH"
      ${pkgs-unstable.bash}/bin/bash scripts/check-ephemeral-refs.sh
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-ephemeral-refs.sh --advisory
    ''}";
    files = "^(README\\.md|CONTRIBUTING\\.md|SECURITY\\.md|\\.github/PULL_REQUEST_TEMPLATE\\.md|docs/.*\\.md|tests/README\\.md|scripts/.*\\.sh|tests/.*\\.sh|nix/.*\\.nix|flake\\.nix|treefmt\\.nix|\\.github/.*\\.ya?ml|docs/_data/.*\\.ya?ml|[^/]*\\.ya?ml)$";
    # The YAML alternatives are derived from where YAML actually sits in
    # this repo — `.github/**` (workflows, composite actions, issue
    # templates, config), `docs/_data/`, and the root-level config
    # files — rather than from `.github/workflows` alone, which would
    # leave a composite action's comments able to drift without ever
    # tripping the hook that gates them.
    # `tests/.*\.sh` above reaches the fixture trees, which the lint
    # skips outright — staging one would buy a full-tree scan that
    # cannot report on the file that triggered it. Keep the trigger
    # aligned with the lint's own allowlist.
    excludes = [ "^tests/fixtures/" ];
    # The advisory pass always exits 0, and pre-commit shows a passing
    # hook's output only when the hook is verbose. Without this the
    # second invocation is a silent no-op that costs a scan per commit
    # and surfaces nothing an author could act on.
    verbose = true;
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
      export PATH="${toolPath}:$PATH"
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-cron-table.sh
    ''}";
    files = "^(\\.github/workflows/.*\\.ya?ml|docs/architecture/ci\\.md|scripts/check-cron-table\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  # Asserts docs outside ci.md never restate a literal workflow cron
  # time: a line naming a workflow and carrying an HH:MM clock time
  # belongs only in the ci.md schedule table; other docs link it.
  check-doc-cron-restatement = {
    enable = true;
    name = "check-doc-cron-restatement";
    description = "Docs outside ci.md must link the cron schedule table, not restate literal workflow times.";
    entry = "${pkgs-unstable.writeShellScript "check-doc-cron-restatement-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      export PATH="${toolPath}:$PATH"
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-doc-cron-restatement.sh
    ''}";
    files = "^(README\\.md|docs/.*\\.md|\\.github/workflows/.*\\.ya?ml|scripts/check-doc-cron-restatement\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
}
