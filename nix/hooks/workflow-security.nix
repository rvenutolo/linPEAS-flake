{
  pkgs-unstable,
  actionlintWrapped,
  ...
}:
{
  # Belt-and-braces backup to the GitHub-side
  # `sha_pinning_required` setting. Mirrors the NIX_BUILD_TOP guard used
  # by flake-show-fresh so nix flake check doesn't fail
  # inside the sandbox where the script can't reach .github/.
  uses-sha-pinned = {
    enable = true;
    name = "uses-sha-pinned";
    description = "Every uses: reference is SHA-pinned.";
    entry = "${pkgs-unstable.writeShellScript "uses-sha-pinned-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-uses-sha-pinned.sh
    ''}";
    files = "^(\\.github/workflows/.*\\.ya?ml|\\.github/actions/.*\\.ya?ml|scripts/check-uses-sha-pinned\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  patch-tag-pins = {
    enable = true;
    name = "patch-tag-pins";
    description = "SHA-pinned uses: comments name exact patch tag (vX.Y.Z), not major (vX).";
    entry = "${pkgs-unstable.writeShellScript "patch-tag-pins-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-patch-tag-pins.sh
    ''}";
    files = "^(\\.github/workflows/.*\\.ya?ml|\\.github/actions/.*\\.ya?ml|scripts/check-patch-tag-pins\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  # Asserts every job in .github/workflows/*.yml starts with
  # step-security/harden-runner as its first step. Belt-and-braces
  # lint mirrors the trust-model invariant; eBPF monitor must
  # install before any I/O.
  harden-runner-first = {
    enable = true;
    name = "harden-runner-first";
    description = "Every workflow job's first step is step-security/harden-runner.";
    entry = "${pkgs-unstable.writeShellScript "harden-runner-first-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      export PATH="${pkgs-unstable.yq-go}/bin:$PATH"
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-harden-runner-first.sh
    ''}";
    files = "^(\\.github/workflows/.*\\.ya?ml|scripts/check-harden-runner-first\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  # Strict least-privilege lint: every workflow's top-level
  # permissions: must be `{}` and every job must declare its
  # own scopes. See docs/security/min-permissions.md.
  min-permissions = {
    enable = true;
    name = "min-permissions";
    description = "Top-level workflow permissions empty; each job declares its own scopes.";
    entry = "${pkgs-unstable.writeShellScript "min-permissions-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      export PATH="${pkgs-unstable.yq-go}/bin:$PATH"
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-min-permissions.sh
    ''}";
    files = "^(\\.github/workflows/.*\\.ya?ml|scripts/check-min-permissions\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  # Every job under .github/workflows/ declares an explicit
  # timeout-minutes. The default is 6 hours; without an
  # explicit cap a hung job burns the runner budget and stalls
  # the merge queue. See docs/security/workflow-hardening.md.
  job-timeout-minutes = {
    enable = true;
    name = "job-timeout-minutes";
    description = "Every workflow job declares an explicit timeout-minutes.";
    entry = "${pkgs-unstable.writeShellScript "job-timeout-minutes-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      export PATH="${pkgs-unstable.yq-go}/bin:$PATH"
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-job-timeout-minutes.sh
    ''}";
    files = "^(\\.github/workflows/.*\\.ya?ml|scripts/check-job-timeout-minutes\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  # Every workflow declares a top-level concurrency.group so
  # parallel runs on the same ref don't pile up. Without one,
  # cron and back-to-back PR pushes can spawn racing runs that
  # touch shared remote state. See docs/security/workflow-hardening.md.
  workflow-concurrency = {
    enable = true;
    name = "workflow-concurrency";
    description = "Every workflow declares a top-level concurrency.group.";
    entry = "${pkgs-unstable.writeShellScript "workflow-concurrency-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      export PATH="${pkgs-unstable.yq-go}/bin:$PATH"
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-workflow-concurrency.sh
    ''}";
    files = "^(\\.github/workflows/.*\\.ya?ml|scripts/check-workflow-concurrency\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  # Every actions/checkout step sets persist-credentials: false
  # so GITHUB_TOKEN isn't written into .git/config and left on
  # disk for later steps to read. See
  # docs/security/workflow-hardening.md.
  checkout-persist-credentials = {
    enable = true;
    name = "checkout-persist-credentials";
    description = "Every actions/checkout sets with.persist-credentials: false.";
    entry = "${pkgs-unstable.writeShellScript "checkout-persist-credentials-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      export PATH="${pkgs-unstable.yq-go}/bin:$PATH"
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-checkout-persist-credentials.sh
    ''}";
    files = "^(\\.github/workflows/.*\\.ya?ml|scripts/check-checkout-persist-credentials\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  # Every actions/upload-artifact step sets if-no-files-found:
  # error so a broken path: glob fails the job instead of
  # silently uploading an empty artifact. See
  # docs/security/workflow-hardening.md.
  upload-artifact-strict = {
    enable = true;
    name = "upload-artifact-strict";
    description = "Every actions/upload-artifact sets with.if-no-files-found: error.";
    entry = "${pkgs-unstable.writeShellScript "upload-artifact-strict-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      export PATH="${pkgs-unstable.yq-go}/bin:$PATH"
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-upload-artifact-strict.sh
    ''}";
    files = "^(\\.github/workflows/.*\\.ya?ml|scripts/check-upload-artifact-strict\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  # Every pull_request: / push: trigger explicitly declares
  # branches: [main]. Implicit all-branches triggers waste
  # runner minutes on stale topic branches. See
  # docs/security/workflow-hardening.md.
  workflow-on-branches = {
    enable = true;
    name = "workflow-on-branches";
    description = "pull_request: and push: declare branches: [main] explicitly.";
    entry = "${pkgs-unstable.writeShellScript "workflow-on-branches-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      export PATH="${pkgs-unstable.yq-go}/bin:$PATH"
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-workflow-on-branches.sh
    ''}";
    files = "^(\\.github/workflows/.*\\.ya?ml|scripts/check-workflow-on-branches\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  # Hard-ban the pull_request_target trigger. Running the base
  # ref's workflow with full secret scope while operating on
  # head-ref code is the canonical Actions privilege-escalation
  # footgun. See docs/security/workflow-hardening.md.
  pull-request-target-absent = {
    enable = true;
    name = "pull-request-target-absent";
    description = "No workflow uses the pull_request_target trigger.";
    entry = "${pkgs-unstable.writeShellScript "pull-request-target-absent-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      export PATH="${pkgs-unstable.yq-go}/bin:$PATH"
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-pull-request-target-absent.sh
    ''}";
    files = "^(\\.github/workflows/.*\\.ya?ml|scripts/check-pull-request-target-absent\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  # Release-grade jobs include the fork-guard if: clause.
  # See docs/security/workflow-hardening.md.
  fork-guard-release = {
    enable = true;
    name = "fork-guard-release";
    description = "Release-grade jobs include github.repository fork guard.";
    entry = "${pkgs-unstable.writeShellScript "fork-guard-release-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      export PATH="${pkgs-unstable.yq-go}/bin:$PATH"
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-fork-guard-release.sh
    ''}";
    files = "^(\\.github/workflows/.*\\.ya?ml|scripts/check-fork-guard-release\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  # Every gh attestation verify invocation passes --repo.
  # See docs/security/verification.md.
  gh-attestation-repo = {
    enable = true;
    name = "gh-attestation-repo";
    description = "gh attestation verify pins --repo rvenutolo/linPEAS-flake.";
    entry = "${pkgs-unstable.writeShellScript "gh-attestation-repo-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-gh-attestation-repo.sh
    ''}";
    files = "^(\\.github/workflows/.*\\.ya?ml|scripts/.*\\.sh|docs/.*\\.md|README\\.md|SECURITY\\.md)$";
    pass_filenames = false;
    language = "system";
  };
  # cosign verify pins identity + OIDC issuer.
  # See docs/security/verification.md.
  cosign-identity-pinned = {
    enable = true;
    name = "cosign-identity-pinned";
    description = "cosign verify pins --certificate-identity[-regexp] + --certificate-oidc-issuer.";
    entry = "${pkgs-unstable.writeShellScript "cosign-identity-pinned-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-cosign-identity-pinned.sh
    ''}";
    files = "^(\\.github/workflows/.*\\.ya?ml|scripts/.*\\.sh|docs/.*\\.md|README\\.md|SECURITY\\.md)$";
    pass_filenames = false;
    language = "system";
  };
  # Ban unpinned nix run nixpkgs#<pkg> invocations.
  # See docs/security/workflow-hardening.md.
  nix-run-pinned = {
    enable = true;
    name = "nix-run-pinned";
    description = "No unpinned nix run nixpkgs#<pkg>; use nix shell .#<pkg> or pin a rev.";
    entry = "${pkgs-unstable.writeShellScript "nix-run-pinned-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-nix-run-pinned.sh
    ''}";
    files = "^(\\.github/workflows/.*\\.ya?ml|scripts/.*\\.sh|docs/.*\\.md|README\\.md|SECURITY\\.md)$";
    pass_filenames = false;
    language = "system";
  };
  # Catches divergence between the SHA in flake.nix's
  # pre-commit-hooks input URL and the locked.rev in flake.lock.
  # Fires when either file changes. NIX_BUILD_TOP guard skips
  # inside the flake-check sandbox where git is not available.
  pre-commit-hooks-sha-parity = {
    enable = true;
    name = "pre-commit-hooks-sha-parity";
    description = "The pre-commit-hooks input SHA in flake.nix matches flake.lock locked.rev.";
    entry = "${pkgs-unstable.writeShellScript "pre-commit-hooks-sha-parity-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-pre-commit-hooks-sha-parity.sh
    ''}";
    files = "^(flake\\.nix|flake\\.lock|scripts/check-pre-commit-hooks-sha-parity\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
  # Canary: assert actionlint's embedded shellcheck
  # integration is wired. Runs the wrapper-pinned actionlint
  # binary against tests/fixtures/actionlint-shellcheck-smoke.yml
  # (which has a planted SC2086) and fails if the finding is
  # not surfaced. Guards against silent regression of the
  # shellcheck pin in actionlintWrapped. See
  # docs/actionlint-embedded-linters.md.
  actionlint-shellcheck-active = {
    enable = true;
    name = "actionlint-shellcheck-active";
    description = "actionlint shellcheck integration canary.";
    entry = "${pkgs-unstable.writeShellScript "check-actionlint-shellcheck-active-hook" ''
      set -Eeuo pipefail
      IFS=$'\n\t'
      if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
      export PATH="${actionlintWrapped}/bin:$PATH"
      exec ${pkgs-unstable.bash}/bin/bash scripts/check-actionlint-shellcheck-active.sh
    ''}";
    files = "^(flake\\.nix|tests/fixtures/actionlint-shellcheck-smoke\\.yml|scripts/check-actionlint-shellcheck-active\\.sh)$";
    pass_filenames = false;
    language = "system";
  };
}
