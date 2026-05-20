# Required Status Checks — main branch

Snapshot of the `protect-main` branch ruleset
(`gh api repos/rvenutolo/linPEAS-flake/rules/branches/main`) as of
2026-05-19. Update this file in the same change as any modification to the
ruleset.

> Migration note: prior to 2026-05-18 these checks were enforced via classic
> branch protection (`branches/main/protection`). They are now enforced via
> a repository ruleset (`rulesets/<id>`, name `protect-main`). On 2026-05-19
> the ruleset was further reshaped to merge-commit-only with
> `required_signatures` retained and `required_linear_history` dropped;
> the required-check set gained `pr-title-lint`.

## Required contexts

| Context                     | Source workflow   | Source file                             |
| --------------------------- | ----------------- | --------------------------------------- |
| flake-check                 | ci                | .github/workflows/ci.yml                |
| build-linpeas               | ci                | .github/workflows/ci.yml                |
| smoke-test                  | ci                | .github/workflows/ci.yml                |
| build-linpeas-arm64         | ci                | .github/workflows/ci.yml                |
| smoke-test-arm64            | ci                | .github/workflows/ci.yml                |
| image-smoke                 | ci                | .github/workflows/ci.yml                |
| image-smoke-arm64           | ci                | .github/workflows/ci.yml                |
| bundle-smoke                | ci                | .github/workflows/ci.yml                |
| dashboard-data-tests        | ci                | .github/workflows/ci.yml                |
| required-checks-no-paths    | ci                | .github/workflows/ci.yml                |
| pr-workflows-no-secrets     | ci                | .github/workflows/ci.yml                |
| tag-protection-drift-check  | ci                | .github/workflows/ci.yml                |
| renovate-invariants         | ci                | .github/workflows/ci.yml                |
| pre-commit-hooks-sha-parity | ci                | .github/workflows/ci.yml                |
| pin-diff-isolated           | ci                | .github/workflows/ci.yml                |
| uses-sha-pinned             | ci                | .github/workflows/ci.yml                |
| markdownlint                | ci                | .github/workflows/ci.yml                |
| typos                       | ci                | .github/workflows/ci.yml                |
| editorconfig                | ci                | .github/workflows/ci.yml                |
| check-jsonschema            | ci                | .github/workflows/ci.yml                |
| commitlint                  | ci                | .github/workflows/ci.yml                |
| lint-pr-title               | pr-title-lint     | .github/workflows/pr-title-lint.yml     |
| dependency-review           | dependency-review | .github/workflows/dependency-review.yml |
| gitleaks                    | gitleaks          | .github/workflows/gitleaks.yml          |

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

1. Update the table above to match.

1. If a new workflow file appears in column 3, verify it does not declare
    `paths:` / `paths-ignore:` under `pull_request:`. The lint will catch
    this on PR, but the doc must reflect reality.

1. Read the current list with:

    ```sh
    gh api repos/rvenutolo/linPEAS-flake/rules/branches/main \
      --jq '.[] | select(.type=="required_status_checks")
                 | .parameters.required_status_checks[].context'
    ```

    The ruleset id (for `PUT rulesets/<id>` updates) can be discovered with:

    ```sh
    gh api repos/rvenutolo/linPEAS-flake/rulesets \
      --jq '.[] | select(.name=="protect-main") | .id'
    ```
