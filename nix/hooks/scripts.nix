{
  pkgs-unstable,
  ...
}:
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
  # No scripts/*.sh feeds a redirection from a yq process substitution
  # (`< <(yq ...)`) — a procsub's exit status is invisible under
  # set -Eeuo pipefail, so a yq parse failure fails open instead of
  # loud. See docs/security/workflow-hardening.md.
  no-parser-procsub = {
    enable = true;
    name = "no-parser-procsub";
    description = "No scripts/*.sh feeds a redirection from a yq or jq process substitution.";
    entry = "${pkgs-unstable.writeShellScript "no-parser-procsub-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-no-parser-procsub.sh
    ''}";
    files = "^scripts/.*\\.sh$";
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
  # Every manifest-reading freshness hook watches nix/hooks in its
  # files filter, so a hook-definition edit re-triggers the freshness
  # check on the per-changed-file git commit path. See
  # docs/security/workflow-hardening.md.
  manifest-hook-watches-nix = {
    enable = true;
    name = "manifest-hook-watches-nix";
    description = "Every manifest-reading freshness hook watches nix/hooks in its files filter.";
    entry = "${pkgs-unstable.writeShellScript "manifest-hook-watches-nix-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-manifest-hook-watches-nix.sh
    ''}";
    files = "^(nix/hooks/.*\\.nix|scripts/.*\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  # Every devTooling-evaluating freshness hook watches every nix module
  # its generator reads, so a module edit re-triggers the freshness check
  # on the per-changed-file git commit path. See
  # docs/security/workflow-hardening.md.
  freshness-hook-watches-modules = {
    enable = true;
    name = "freshness-hook-watches-modules";
    description = "Every devTooling-evaluating freshness hook watches every nix module its generator reads.";
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
  # Every tool the .#lint lint groups rely on is present on
  # PATH. Keeps devShells.lint buildInputs from silently dropping a
  # tool. See docs/security/workflow-hardening.md.
  lint-shell-tools = {
    enable = true;
    name = "lint-shell-tools";
    description = "Every tool the .#lint lint groups need is on PATH.";
    entry = "${pkgs-unstable.writeShellScript "lint-shell-tools-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-lint-shell-tools.sh
    ''}";
    files = "^(scripts/check-lint-shell-tools\\.sh|nix/devshell-lint\\.nix)$";
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
  check-run-block-pyflakes-required = {
    enable = true;
    name = "check-run-block-pyflakes-required";
    description = "Fail if a workflow run: invokes python without pyflakes wired.";
    entry = "${pkgs-unstable.writeShellScript "check-run-block-pyflakes-required-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-run-block-pyflakes-required.sh
    ''}";
    files = "^(\\.github/(workflows|actions)/.*\\.ya?ml|scripts/check-run-block-pyflakes-required\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
}
