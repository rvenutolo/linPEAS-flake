# Default: list recipes
default:
  @just --list

# Build the linpeas package
build:
  nix build .#linpeas

# Run all flake checks (eval, formatting, pre-commit)
check:
  nix flake check

# Format every file via treefmt
fmt:
  nix fmt

# Run pre-commit hooks against all files
lint:
  pre-commit run --all-files

# Run lychee link checker against tracked markdown files
lint-links:
  lychee --config lychee.toml README.md SECURITY.md 'docs/**/*.md'

# Run every script-based check and test harness (excludes nix-build and link-check jobs)
verify:
  nix develop --command bash -c '\
  set -Eeuo pipefail; \
  ./scripts/check-uses-sha-pinned.sh; \
  ./scripts/check-harden-runner-first.sh; \
  ./scripts/check-min-permissions.sh; \
  ./scripts/check-job-timeout-minutes.sh; \
  ./scripts/check-workflow-concurrency.sh; \
  ./scripts/check-checkout-persist-credentials.sh; \
  ./scripts/check-upload-artifact-strict.sh; \
  ./scripts/check-workflow-on-branches.sh; \
  ./scripts/check-pull-request-target-absent.sh; \
  ./scripts/check-script-shebang-pipefail.sh; \
  ./scripts/check-script-has-test.sh; \
  ./scripts/check-ci-job-in-summary.sh; \
  ./scripts/check-run-block-strict.sh; \
  ./scripts/check-fork-guard-release.sh; \
  ./scripts/check-pr-workflows-no-secrets.sh; \
  ./scripts/check-required-checks-no-paths.sh; \
  ./scripts/check-tag-protection.sh; \
  ./scripts/check-renovate-invariants.sh; \
  ./scripts/check-protect-main.sh; \
  ./scripts/check-jsonschema.sh; \
  ./scripts/check-pre-commit-hooks-sha-parity.sh; \
  ./scripts/check-pin-diff-isolated.sh; \
  bash tests/check-uses-sha-pinned.test.sh; \
  bash tests/check-harden-runner-first.test.sh; \
  bash tests/check-min-permissions.test.sh; \
  bash tests/check-job-timeout-minutes.test.sh; \
  bash tests/check-workflow-concurrency.test.sh; \
  bash tests/check-checkout-persist-credentials.test.sh; \
  bash tests/check-upload-artifact-strict.test.sh; \
  bash tests/check-workflow-on-branches.test.sh; \
  bash tests/check-pull-request-target-absent.test.sh; \
  bash tests/check-script-shebang-pipefail.test.sh; \
  bash tests/check-script-has-test.test.sh; \
  bash tests/check-ci-job-in-summary.test.sh; \
  bash tests/check-run-block-strict.test.sh; \
  bash tests/check-fork-guard-release.test.sh; \
  bash tests/check-pr-workflows-no-secrets.test.sh; \
  bash tests/check-required-checks-no-paths.test.sh; \
  bash tests/check-tag-protection.test.sh; \
  bash tests/check-renovate-invariants.test.sh; \
  bash tests/check-protect-main.test.sh; \
  bash tests/check-pre-commit-hooks-sha-parity.test.sh; \
  bash tests/check-pin-diff-isolated.test.sh; \
  bash tests/gen-dashboard-data.test.sh; \
  bash tests/refresh-ci-summary.test.sh; \
  bash tests/refresh-just-recipes.test.sh; \
  bash tests/refresh-precommit-table.test.sh'

# Manually refresh linpeas pin from upstream latest release
bump:
  ./scripts/bump-linpeas.sh

# Regenerate the <!-- BEGIN/END flake-show --> block in docs/reference/flake-outputs.md
show:
  ./scripts/refresh-flake-show.sh

# Regenerate the pre-commit hook table in docs/development/git.md
show-hooks:
  ./scripts/refresh-precommit-table.sh

# Regenerate the just-recipes list in README.md
show-recipes:
  ./scripts/refresh-just-recipes.sh

# Regenerate the Continuous integration summary in README.md
show-ci-summary:
  ./scripts/refresh-ci-summary.sh

# Build the OCI image
image:
  nix build .#linpeas-image

# Build the Pages site
site:
  nix build "path:$(pwd)#site"

# Live-preview site at http://127.0.0.1:8000 (regenerates data first)
site-dev:
  ./scripts/gen-dashboard-data.sh
  mkdocs serve

# Regenerate docs/_data/dashboard.yml standalone
site-data:
  ./scripts/gen-dashboard-data.sh
