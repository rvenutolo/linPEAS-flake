# Required Status Checks — main branch

In-tree restatement of the required-context set from the `protect-main`
branch ruleset (`gh api repos/rvenutolo/linPEAS-flake/rules/branches/main`).
`docs/_data/ci-check-categories.yml` restates the same set, parity-gated by
`scripts/refresh-ci-summary.sh`. Update this file in the same change as any
modification to the ruleset.

## Required contexts

| Context                  | Source workflow   | Source file                             |
| ------------------------ | ----------------- | --------------------------------------- |
| flake-check              | ci                | .github/workflows/ci.yml                |
| build-linpeas            | ci                | .github/workflows/ci.yml                |
| smoke-test               | ci                | .github/workflows/ci.yml                |
| build-linpeas-arm64      | ci                | .github/workflows/ci.yml                |
| smoke-test-arm64         | ci                | .github/workflows/ci.yml                |
| image-smoke              | ci                | .github/workflows/ci.yml                |
| image-smoke-arm64        | ci                | .github/workflows/ci.yml                |
| lint-workflow-security   | ci                | .github/workflows/ci.yml                |
| lint-script-hygiene      | ci                | .github/workflows/ci.yml                |
| lint-doc-invariants      | ci                | .github/workflows/ci.yml                |
| cliff-tag-pattern        | ci                | .github/workflows/ci.yml                |
| changelog-links          | ci                | .github/workflows/ci.yml                |
| commitlint               | ci                | .github/workflows/ci.yml                |
| dashboard-data-tests     | ci                | .github/workflows/ci.yml                |
| required-checks-no-paths | ci                | .github/workflows/ci.yml                |
| setup-nix-required       | ci                | .github/workflows/ci.yml                |
| pr-workflows-no-secrets  | ci                | .github/workflows/ci.yml                |
| harness-group            | ci                | .github/workflows/ci.yml                |
| renovate-invariants      | ci                | .github/workflows/ci.yml                |
| markdownlint             | ci                | .github/workflows/ci.yml                |
| typos                    | ci                | .github/workflows/ci.yml                |
| editorconfig             | ci                | .github/workflows/ci.yml                |
| doc-freshness            | ci                | .github/workflows/ci.yml                |
| lint-pr-title            | pr-title-lint     | .github/workflows/pr-title-lint.yml     |
| dependency-review        | dependency-review | .github/workflows/dependency-review.yml |
| gitleaks                 | gitleaks          | .github/workflows/gitleaks.yml          |
| trufflehog               | trufflehog        | .github/workflows/trufflehog.yml        |

## Path-filter invariant

No workflow listed above may declare `paths:` or `paths-ignore:` under its
`on.pull_request:` trigger. Such a filter creates the auto-merge
path-filter trap: PRs that touch only filtered-out paths skip the check
entirely, and `gh pr merge --auto --merge` would merge them with reduced
coverage.

Enforced by `scripts/check-required-checks-no-paths.sh`, wired as the
`required-checks-no-paths` job in `ci.yml`. That job itself is in the
required-check list above, so the enforcement is self-bootstrapping
(no PR can land on `main` while the lint is red).

## Maintenance

When the ruleset's required-check list changes:

1. Update the table above to match. Also update `docs/_data/ci-check-categories.yml`
    in the same change — `scripts/refresh-ci-summary.sh` fails if the two sets diverge.

1. If a new workflow file appears in column 3, verify it does not declare
    `paths:` / `paths-ignore:` under `pull_request:`. The lint will catch
    this on PR, but the doc must reflect reality.

1. Read the current list with:

    ```sh
    gh api repos/rvenutolo/linPEAS-flake/rules/branches/main \
      --jq '.[] | select(.type=="required_status_checks")
                | .parameters.required_status_checks[].context'
    ```
