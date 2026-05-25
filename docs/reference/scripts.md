# Scripts reference

Auto-generated from in-script `@description` / `@arg` / `@option` /
`@example` annotations by `scripts/refresh-scripts-reference.sh`.
Do not edit between the markers.

<!-- BEGIN scripts-reference -->

{% raw %}

## Check scripts

### scripts/check-actionlint-shellcheck-active.sh

Canary: assert actionlint's embedded shellcheck
integration is wired. Runs the (wrapper-pinned) actionlint
binary against a fixture workflow containing a planted SC2086
violation; fails if the SC2086 code does not appear in output.

If this script fails, the actionlint hook has silently stopped
invoking shellcheck on `run:` blocks. See
docs/actionlint-embedded-linters.md.

Env overrides (test-only):
ACTIONLINT_SMOKE_FIXTURE_OVERRIDE — alternate fixture path

Exits 0 on clean, 1 on any failure.

### scripts/check-allowed-actions-api.sh

Assert the live `actions.permissions.allowed_actions`
API state matches the canonical allowlist documented in
`docs/security/allowed-actions.md`.

### scripts/check-checkout-persist-credentials.sh

Lint: every `actions/checkout` step in every workflow
sets `with.persist-credentials: false` so the GITHUB_TOKEN is not
left in `.git/config` for subsequent steps to read.

### scripts/check-ci-job-in-summary.sh

Lint: cross-check `.github/workflows/ci.yml` jobs
against `docs/_data/ci-check-categories.yml` in both directions,
with an EXEMPT list for auxiliary (non-required) jobs.

### scripts/check-cliff-tag-pattern.sh

Refuse to build if cliff.toml's tag_pattern drifts from the
canonical pin-shape regex. Joins the cross-layer parity set enforced in
bump-linpeas.sh, flake.nix, stale-pin-check.yml, release-on-bump.yml,
and gen-dashboard-data.sh.

Exits 0 when tag_pattern exactly matches the canonical value.
Exits 1 on any failure (missing file, missing key, wrong value).

Env overrides (test-only):
CLIFF_TOML_OVERRIDE — path to a fixture cliff.toml instead of
the repo-root cliff.toml

### scripts/check-cosign-identity-pinned.sh

Lint: every `cosign verify` invocation pins both
`--certificate-identity` (or `-regexp`) and `--certificate-oidc-issuer`
so verification is bound to a specific signer.

### scripts/check-doc-anchors.sh

Lint: every markdown #anchor link pointing at an
in-tree .md (or same-file fragment) must match a heading slug in
the target file.

### scripts/check-fork-guard-release.sh

Lint: every workflow job holding release-grade
GITHUB_TOKEN scope (contents/packages/id-token/attestations: write)
carries a fork-guard `if:` pinning execution to the canonical repo.

### scripts/check-gh-api-version-header.sh

Lint: every `gh api` invocation and `api.github.com`
request in scripts/\*.sh passes an explicit
`X-GitHub-Api-Version: <date>` header.

### scripts/check-gh-attestation-repo.sh

Lint: every `gh attestation verify` invocation across
workflows, scripts, and docs passes `--repo rvenutolo/linPEAS-flake`
so verification is bound to this repository.

### scripts/check-hammer-shim-parity.sh

Lint: nix/hammer-shim.nix's linpeas derivation matches
flake.nix's linpeas derivation. The shim duplicates the derivation
because `builtins.getFlake` cannot run inside the `nix flake check`
sandbox. Compares bodies normalized to whitespace-collapsed form.
Exits 0 on match, 1 on drift, 2 if extraction fails.

Env overrides (test-only):
FLAKE_NIX_OVERRIDE — path to flake.nix to read
HAMMER_SHIM_OVERRIDE — path to nix/hammer-shim.nix to read

### scripts/check-harden-runner-first.sh

Lint: every job in .github/workflows/\*.yml begins
with `step-security/harden-runner@<sha>` as its first step, so the
eBPF monitor installs before any I/O.

### scripts/check-job-timeout-minutes.sh

Lint: every job under .github/workflows/\*.yml
declares an explicit `timeout-minutes`, bounding blast radius
from hung jobs. Reusable-workflow jobs are exempt.

### scripts/check-jsonschema.sh

Validate repo config files (renovate.json, workflow
YAML, composite-action YAML, .markdownlint.json) against pinned
JSON Schemas using `check-jsonschema`.

### scripts/check-min-permissions.sh

Strict least-privilege lint for GitHub Actions
GITHUB_TOKEN scopes: top-level `permissions: {}` and an explicit
per-job `permissions:` block in every workflow.

### scripts/check-nix-run-pinned.sh

Lint: ban unpinned `nix run nixpkgs#<pkg>` invocations
across workflows, scripts, and shell-fenced markdown. Allowed
alternatives use the repo's own flake or an explicit commit pin.

### scripts/check-orphan-invariants.sh

Lint: docs/invariant-index.md and docs/\*\*/\*.md stay
in lockstep — every index pointer resolves to a real file, and
every non-EXEMPT docs file has an index entry.

### scripts/check-pin-diff-isolated.sh

Lint: exactly one script under `scripts/` writes to
`linpeas-pin.json` (bump-linpeas.sh), so the
`release-on-bump.yml` path-filter trigger contract is
self-enforcing.

### scripts/check-pre-commit-hooks-sha-parity.sh

Lint: the SHA embedded in `flake.nix`'s
`pre-commit-hooks` input URL matches `flake.lock`'s pinned
`pre-commit-hooks.locked.rev`.

### scripts/check-protect-main.sh

Lint: the live `protect-main` branch ruleset matches
the desired posture AND the in-tree mirror at
`.github/rulesets/protect-main.json`.

### scripts/check-pr-workflows-no-secrets.sh

Lint: no workflow triggered by `pull_request` /
`pull_request_target` references any `secrets.*` other than
`secrets.GITHUB_TOKEN`.

### scripts/check-pull-request-target-absent.sh

Lint: hard-fail if any workflow under
.github/workflows/\*.yml uses the `pull_request_target` trigger,
foreclosing the canonical Actions privilege-escalation footgun.

### scripts/check-renovate-config-validator.sh

Validate renovate.json against the upstream Renovate
config schema using `renovate-config-validator --strict --no-global`.
Catches typoed keys, wrong-type values, and unknown options that
per-tool linters miss. Complements scripts/check-renovate-invariants.sh,
which asserts repo-policy invariants on top of a valid schema.

Honors RENOVATE_JSON_OVERRIDE for fixture testing.
Exits 0 on a valid config, 1 on any validation error.

### scripts/check-renovate-invariants.sh

Lint: renovate.json carries the security-critical
invariants — pinGitHubActionDigests, minimumReleaseAge, no top-level
automerge, per-manager pinDigests for github-actions.

### scripts/check-required-checks-no-paths.sh

Lint: no workflow listed in
docs/security/required-checks.md declares `paths:` or
`paths-ignore:` under `on.pull_request:` — avoiding the auto-merge
path-filter skip trap.

### scripts/check-run-block-strict.sh

Lint: every multi-line `run:` block under
`.github/workflows/*.yml` starts with `set -Eeuo pipefail` as its
first non-blank, non-comment line.

### scripts/check-script-has-test.sh

Lint: every `scripts/check-*.sh` has a matching
`tests/check-*.test.sh` and vice versa, modulo an explicit EXEMPT
list.

### scripts/check-script-shebang-pipefail.sh

Lint: every `scripts/*.sh` starts with
`#!/usr/bin/env bash` (exact first line) and contains
`set -Eeuo pipefail` somewhere in the file.

### scripts/check-settings-posture.sh

Lint: every gh-API-verifiable row in
`docs/security/settings-posture.md` matches the live repository
configuration. Manual-UI rows are out of scope.

### scripts/check-setup-nix-required.sh

Lint: every workflow installing Nix goes through the
composite `./.github/actions/setup-nix` and passes
`github-token: ${{ secrets.GITHUB_TOKEN }}`.

### scripts/check-tag-protection.sh

Lint: the live `release-tag-protection` ruleset
matches the desired posture (tag target, active enforcement, ref
include pattern, required rules).

### scripts/check-upload-artifact-strict.sh

Lint: every `actions/upload-artifact` step in every
workflow under `.github/workflows/*.yml` sets
`with.if-no-files-found: error` so empty-glob bugs hard-fail.

### scripts/check-uses-sha-pinned.sh

Lint: every `uses:` in `.github/workflows/*.yml` and
`.github/actions/**/action.yml` ends with a full 40-hex SHA, or is
a local path-relative reference.

### scripts/check-workflow-concurrency.sh

Lint: every workflow under .github/workflows/\*.yml
declares a top-level `concurrency:` block with a non-empty
`group:` string.

### scripts/check-workflow-on-branches.sh

Lint: every workflow declaring `on.pull_request:` or
`on.push:` explicitly sets `branches: [main]` under that trigger
— no wildcards, no implicit all-branches.

## Refresh scripts

### scripts/refresh-ci-dag.sh

Regenerate the ci-dag managed block in
docs/architecture/ci-dag.md from .github/workflows/ci.yml plus the
docs/\_data/ci-check-categories.yml map.

**Options:**

- `--check` — exit 1 if the doc would change; exit 2 if ci.yml has

### scripts/refresh-ci-summary.sh

Regenerate the ci-summary managed block in README.md
from required-checks.md plus the ci-check-categories.yml map.

**Options:**

- `--check` — exit 1 if README.md would change; do not mutate the working tree

### scripts/refresh-enforcement-matrix.sh

Regenerate docs/security/enforcement-matrix.md from
the inline enforcer annotations on every bullet of
docs/invariant-index.md, with bidirectional orphan checks.

**Options:**

- `--check` — exit 1 if the matrix would change; do not mutate the working tree

### scripts/refresh-flake-show.sh

Regenerate the flake-show managed block in
docs/reference/flake-outputs.md from `nix flake show --all-systems`.

**Options:**

- `--check` — exit 1 if the doc would change; do not mutate the working tree

### scripts/refresh-just-recipes.sh

Regenerate the just-recipes managed block in
README.md and docs/reference/just-recipes.md from the current
`just` recipe list.

**Options:**

- `--check` — exit 1 if either doc would change; do not mutate the working tree

### scripts/refresh-precommit-table.sh

Regenerate the precommit-table managed block in
docs/development/git.md from the current pre-commit hook manifest
in the flake.

**Options:**

- `--check` — exit 1 if the doc would change; do not mutate the working tree

### scripts/refresh-scripts-reference.sh

Regenerate the scripts-reference managed block in
docs/reference/scripts.md from in-script shdoc-style annotations
parsed by scripts/\_script_docs.awk. Groups entries by basename
prefix into Check / Refresh / Other sections.

**Options:**

- `--check` — exit 1 if drift; do not mutate the working tree

### scripts/refresh-treefmt-config.sh

Regenerate the treefmt-config managed block in
docs/reference/treefmt-config.md from the enabled-formatter manifest
exposed by `flake.nix` as `devTooling.<system>.treefmtConfig`.

**Options:**

- `--check` — exit 1 if the doc would change; do not mutate the working tree

## Other

### scripts/bump-linpeas.sh

Bump linpeas-pin.json to the latest peass-ng/PEASS-ng release.

### scripts/gen-dashboard-data.sh

Generate docs/\_data/dashboard.yml for the MkDocs site
by aggregating pin metadata and live GitHub REST API data.

{% endraw %}

<!-- END scripts-reference -->
