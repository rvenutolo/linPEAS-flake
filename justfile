# Default: list recipes
default:
  @just --list

# Build the linpeas package
build:
  nix build .#linpeas

# Run all flake checks (formatting, pre-commit, lint-shell-tools, derivation build)
check:
  nix flake check

# Format every file via treefmt
fmt:
  nix fmt

# Run pre-commit hooks against all files
lint:
  pre-commit run --all-files

# Run lychee link checker over every markdown file lychee.toml does not exclude, the two dotted trees the recipe names included
lint-links:
  lychee --config lychee.toml './**/*.md' '.github/**/*.md' '.claude/**/*.md'

# Run the lint groups, harnesses, doc-freshness checks, and standalone enforcers CI runs
verify:
  nix develop --command bash -c '\
  rc=0; \
  ./scripts/run-lint-group.sh lint-workflow-security || rc=1; \
  ./scripts/run-lint-group.sh lint-script-hygiene || rc=1; \
  ./scripts/run-lint-group.sh lint-doc-invariants || rc=1; \
  ./scripts/run-harness-group.sh || rc=1; \
  ./scripts/run-doc-freshness.sh || rc=1; \
  ./scripts/check-required-checks-no-paths.sh || rc=1; \
  ./scripts/check-pr-workflows-no-secrets.sh || rc=1; \
  ./scripts/check-tag-protection.sh || rc=1; \
  ./scripts/check-renovate-invariants.sh || rc=1; \
  ./scripts/check-renovate-markers-matched.sh || rc=1; \
  ./scripts/check-protect-main.sh || rc=1; \
  ./scripts/check-setup-nix-required.sh || rc=1; \
  ./scripts/check-cliff-tag-pattern.sh || rc=1; \
  ./scripts/check-changelog-links.sh || rc=1; \
  ./scripts/check-changelog-fresh.sh || rc=1; \
  bash tests/gen-dashboard-data.test.sh || rc=1; \
  exit $rc'

# Manually refresh linpeas pin from upstream latest release
bump:
  ./scripts/bump-linpeas.sh

# Regenerate the <!-- BEGIN/END flake-show --> block in docs/reference/flake-outputs.md
show:
  ./scripts/refresh-flake-show.sh

# Regenerate the pre-commit hook table in docs/development/git.md
show-hooks:
  ./scripts/refresh-precommit-table.sh

# Regenerate the just-recipes list in README.md and docs/reference/just-recipes.md
show-recipes:
  ./scripts/refresh-just-recipes.sh

# Regenerate docs/reference/scripts.md from in-script annotations
show-scripts:
  ./scripts/refresh-scripts-reference.sh

# Regenerate docs/architecture/ci-dag.md from ci.yml needs graph
show-ci-dag:
  ./scripts/refresh-ci-dag.sh

# Regenerate the Continuous integration summary in README.md
show-ci-summary:
  ./scripts/refresh-ci-summary.sh

# Regenerate docs/security/enforcement-matrix.md from invariant-index annotations
show-enforcement-matrix:
  ./scripts/refresh-enforcement-matrix.sh

# Regenerate docs/reference/treefmt-config.md from treefmt.nix
show-treefmt:
  ./scripts/refresh-treefmt-config.sh

# Record the current commit as the point the docs audit was last run against
docs-audit-done:
  ./scripts/mark-docs-audit.sh

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
