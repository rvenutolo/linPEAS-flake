{
  pkgs-unstable,
  ...
}:
let
  # Hooks in this file otherwise run on ambient PATH, which is the right
  # default: their scripts need nothing a shell does not already have.
  # The parse-tree lints are the exception — they read command words from
  # `shfmt --tojson` through `jq`, and a commit made from a shell outside
  # the devShell would otherwise stop at their `require_tool` guard with a
  # could-not-run instead of linting. Pinning the two here resolves the
  # same binaries the devShell does rather than whatever the host ships.
  parserToolPath = pkgs-unstable.lib.makeBinPath [
    pkgs-unstable.jq
    pkgs-unstable.shfmt
  ];
in
{
  # Every scripts/*.sh starts with #!/usr/bin/env bash and
  # contains set -Eeuo pipefail. See docs/security/workflow-hardening.md.
  script-shebang-pipefail = {
    enable = true;
    name = "script-shebang-pipefail";
    description = "Every scripts/*.sh has portable shebang + set -Eeuo pipefail.";
    entry = "${pkgs-unstable.writeShellScript "script-shebang-pipefail-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-script-shebang-pipefail.sh
    ''}";
    files = "^scripts/.*\\.sh$";
    pass_filenames = false;
    language = "system";
  };
  # No scripts/*.sh feeds a redirection from a process substitution,
  # whatever the producer. A substitution's exit status stays in its own
  # subshell and is invisible under set -Eeuo pipefail, so a producer
  # failure hands the consumer an empty result to score as data instead
  # of failing loud. `diff <(...) <(...)` stays legal, because diff
  # consumes both as file arguments and its own status is what the caller
  # acts on. See docs/security/workflow-hardening.md.
  no-opaque-procsub = {
    enable = true;
    name = "no-opaque-procsub";
    description = "No scripts/*.sh feeds a redirection from a process substitution.";
    entry = "${pkgs-unstable.writeShellScript "no-opaque-procsub-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-no-opaque-procsub.sh
    ''}";
    files = "^scripts/.*\\.sh$";
    pass_filenames = false;
    language = "system";
  };
  # Every output-asserting tests/*.test.sh is wired to the discrimination
  # gate, and both exemption ratchets hold. See
  # docs/security/workflow-hardening.md.
  harness-assert-wired = {
    enable = true;
    name = "harness-assert-wired";
    description = "Every output-asserting tests/*.test.sh is wired to the discrimination gate.";
    entry = "${pkgs-unstable.writeShellScript "harness-assert-wired-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-harness-assert-wired.sh
    ''}";
    files = "^(tests/[^/]*\\.test\\.sh|scripts/lib/harness-assert\\.sh|scripts/check-harness-assert-wired\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  # Every scripts/check-*.sh has tests/check-*.test.sh and
  # vice versa. See docs/security/workflow-hardening.md.
  script-has-test = {
    enable = true;
    name = "script-has-test";
    description = "Every scripts/check-*.sh paired with tests/check-*.test.sh.";
    entry = "${pkgs-unstable.writeShellScript "script-has-test-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-script-has-test.sh
    ''}";
    files = "^(scripts/check-.*\\.sh|tests/check-.*\\.test\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  # Every hook that reaches the Nix hook manifest — through the script its
  # entry runs or through a flake attribute its entry evaluates — watches
  # nix/hooks in its files filter, so a hook-definition edit re-triggers the
  # freshness check on the per-changed-file git commit path. See
  # docs/security/workflow-hardening.md.
  manifest-hook-watches-nix = {
    enable = true;
    name = "manifest-hook-watches-nix";
    description = "Every hook reaching the Nix hook manifest watches nix/hooks in its files filter.";
    entry = "${pkgs-unstable.writeShellScript "manifest-hook-watches-nix-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-manifest-hook-watches-nix.sh
    ''}";
    # Resolving an attribute-evaluating hook's subject reads every nix module
    # in the tree to find the one that assigns the attribute, so a module
    # outside nix/hooks can flip this lint's verdict and must re-trigger it.
    files = "^(.*\\.nix|scripts/.*\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  # Every flake-evaluating freshness hook watches every source its
  # evaluation reads, so an edit to one re-triggers the freshness check on
  # the per-changed-file git commit path. See
  # docs/security/workflow-hardening.md.
  freshness-hook-watches-modules = {
    enable = true;
    name = "freshness-hook-watches-modules";
    description = "Every flake-evaluating freshness hook watches every source its evaluation reads.";
    entry = "${pkgs-unstable.writeShellScript "freshness-hook-watches-modules-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-freshness-hook-watches-modules.sh
    ''}";
    # The lint reads every nix module in the tree (including flake.nix,
    # which is not under nix/) plus every scripts/*.sh generator that names
    # the evaluated attribute, so the filter must cover both.
    files = "^(.*\\.nix|scripts/.*\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  # The tool list devShells.lint declares still covers every tool the
  # .#lint lint groups rely on. Builds checks.lint-shell-tools, which runs
  # the guard with PATH set to exactly that list — running the guard
  # against the committer's ambient PATH cannot see a dropped package,
  # since devShells.default carries every expected tool too.
  # See docs/security/workflow-hardening.md.
  lint-shell-tools = {
    enable = true;
    name = "lint-shell-tools";
    description = "devShells.lint declares every tool the .#lint lint groups need.";
    entry = "${pkgs-unstable.writeShellScript "lint-shell-tools-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      # No-op when running inside a nix build sandbox — the
      # `checks.pre-commit` derivation runs every hook, and `nix build`
      # cannot run in the sandbox (no daemon, restricted PATH). The check
      # is a flake check, so `nix flake check` covers that path anyway.
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      exec nix build --no-link \
        ".#checks.${pkgs-unstable.stdenv.hostPlatform.system}.lint-shell-tools"
    ''}";
    files = "^(scripts/check-lint-shell-tools\\.sh|nix/devshell-lint\\.nix|flake\\.nix|flake\\.lock)$";
    pass_filenames = false;
    language = "system";
  };
  # Every ci.yml job either in ci-check-categories.yml or
  # EXEMPT, and every category entry points at a real job.
  # See docs/security/workflow-hardening.md.
  ci-job-in-summary = {
    enable = true;
    name = "ci-job-in-summary";
    description = "ci.yml jobs cross-checked against docs/_data/ci-check-categories.yml.";
    entry = "${pkgs-unstable.writeShellScript "ci-job-in-summary-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      export PATH="${pkgs-unstable.yq-go}/bin:$PATH"
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-ci-job-in-summary.sh
    ''}";
    files = "^(\\.github/workflows/ci\\.yml|docs/_data/ci-check-categories\\.yml|scripts/check-ci-job-in-summary\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  # Every block-scalar or newline-carrying run: block, in a workflow job
  # or a .github/actions composite, starts with set -Eeuo pipefail.
  # See docs/security/workflow-hardening.md.
  run-block-strict = {
    enable = true;
    name = "run-block-strict";
    description = "Block-scalar and newline-carrying run: blocks in workflows and composite actions start with set -Eeuo pipefail.";
    entry = "${pkgs-unstable.writeShellScript "run-block-strict-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      export PATH="${pkgs-unstable.yq-go}/bin:$PATH"
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-run-block-strict.sh
    ''}";
    files = "^(\\.github/workflows/.*\\.ya?ml|\\.github/actions/.*/action\\.ya?ml|scripts/check-run-block-strict\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  # Asserts only scripts/bump-linpeas.sh mutates
  # linpeas-pin.json — the release-on-bump trigger contract
  # depends on this isolation invariant.
  pin-diff-isolated = {
    enable = true;
    name = "pin-diff-isolated";
    description = "Only scripts/bump-linpeas.sh mutates linpeas-pin.json.";
    entry = "${pkgs-unstable.writeShellScript "pin-diff-isolated-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-pin-diff-isolated.sh
    ''}";
    files = "^(scripts/.*\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  # Asserts every `gh api` / `api.github.com` call in
  # scripts/*.sh passes an explicit `X-GitHub-Api-Version`
  # header. Without it, GitHub treats the client as
  # unversioned and may auto-promote it to a future API
  # version whose response shape differs from what the
  # script parses.
  gh-api-version-header = {
    enable = true;
    name = "gh-api-version-header";
    description = "Every gh api / api.github.com call in scripts passes an X-GitHub-Api-Version header.";
    entry = "${pkgs-unstable.writeShellScript "gh-api-version-header-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      export PATH="${parserToolPath}:$PATH"
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-gh-api-version-header.sh
    ''}";
    files = "^(scripts/.*\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  # Asserts scripts/bump-linpeas.sh retains its three supply-chain
  # integrity guards — asset-URL prefix, `.digest` cross-check, and
  # atomic (mktemp + mv) pin write. A refactor that drops any of them
  # would otherwise leave the Bump-script integrity invariant green
  # while the guard no longer exists.
  bump-script-integrity = {
    enable = true;
    name = "bump-script-integrity";
    description = "scripts/bump-linpeas.sh keeps its URL-prefix, .digest, and atomic-write guards.";
    entry = "${pkgs-unstable.writeShellScript "bump-script-integrity-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-bump-script-integrity.sh
    ''}";
    files = "^(scripts/.*\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  # Guard: fail if any GitHub Actions run: block invokes
  # python/python3/pip while pyflakes is not wired into the
  # actionlint hook. No python run: exists today, so this is
  # a passive gate; the day one lands it fails with a pointer
  # to docs/actionlint-embedded-linters.md.
}
