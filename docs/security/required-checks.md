# Required Status Checks — main branch

In-tree mirror of the `protect-main` branch ruleset
(`gh api repos/rvenutolo/linPEAS-flake/rules/branches/main`). Update
this file in the same change as any modification to the ruleset.

## Required contexts

| Context                      | Source workflow   | Source file                             |
| ---------------------------- | ----------------- | --------------------------------------- |
| flake-check                  | ci                | .github/workflows/ci.yml                |
| build-linpeas                | ci                | .github/workflows/ci.yml                |
| smoke-test                   | ci                | .github/workflows/ci.yml                |
| build-linpeas-arm64          | ci                | .github/workflows/ci.yml                |
| smoke-test-arm64             | ci                | .github/workflows/ci.yml                |
| image-smoke                  | ci                | .github/workflows/ci.yml                |
| image-smoke-arm64            | ci                | .github/workflows/ci.yml                |
| check-doc-anchors            | ci                | .github/workflows/ci.yml                |
| check-jsonschema             | ci                | .github/workflows/ci.yml                |
| checkout-persist-credentials | ci                | .github/workflows/ci.yml                |
| ci-job-in-summary            | ci                | .github/workflows/ci.yml                |
| check-orphan-invariants      | ci                | .github/workflows/ci.yml                |
| commitlint                   | ci                | .github/workflows/ci.yml                |
| dashboard-data-tests         | ci                | .github/workflows/ci.yml                |
| required-checks-no-paths     | ci                | .github/workflows/ci.yml                |
| script-has-test              | ci                | .github/workflows/ci.yml                |
| script-shebang-pipefail      | ci                | .github/workflows/ci.yml                |
| pr-workflows-no-secrets      | ci                | .github/workflows/ci.yml                |
| tag-protection-drift-check   | ci                | .github/workflows/ci.yml                |
| protect-main-drift-check     | ci                | .github/workflows/ci.yml                |
| pull-request-target-absent   | ci                | .github/workflows/ci.yml                |
| renovate-invariants          | ci                | .github/workflows/ci.yml                |
| pre-commit-hooks-sha-parity  | ci                | .github/workflows/ci.yml                |
| pin-diff-isolated            | ci                | .github/workflows/ci.yml                |
| upload-artifact-strict       | ci                | .github/workflows/ci.yml                |
| uses-sha-pinned              | ci                | .github/workflows/ci.yml                |
| workflow-concurrency         | ci                | .github/workflows/ci.yml                |
| workflow-on-branches         | ci                | .github/workflows/ci.yml                |
| harden-runner-first          | ci                | .github/workflows/ci.yml                |
| job-timeout-minutes          | ci                | .github/workflows/ci.yml                |
| min-permissions              | ci                | .github/workflows/ci.yml                |
| markdownlint                 | ci                | .github/workflows/ci.yml                |
| typos                        | ci                | .github/workflows/ci.yml                |
| editorconfig                 | ci                | .github/workflows/ci.yml                |
| lint-pr-title                | pr-title-lint     | .github/workflows/pr-title-lint.yml     |
| dependency-review            | dependency-review | .github/workflows/dependency-review.yml |
| gitleaks                     | gitleaks          | .github/workflows/gitleaks.yml          |

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

    The ruleset id (for `PUT rulesets/<id>` updates) can be discovered with:

    ```sh
    gh api repos/rvenutolo/linPEAS-flake/rulesets \
      --jq '.[] | select(.name=="protect-main") | .id'
    ```

## protect-main ruleset (in-tree mirror)

`.github/rulesets/protect-main.json` is the in-tree mirror of the live
`protect-main` branch ruleset (id `16561598`). Live posture +
mirror-parity asserted by `scripts/check-protect-main.sh` via the
`protect-main-drift-check` required CI job. Mirrors the
`tag-protection-drift-check` pattern.

Asserted invariants: name `protect-main`; target `branch`; enforcement
`active`; conditions.ref_name.include == `["~DEFAULT_BRANCH"]`;
bypass_actors == `[]`; rules include `deletion`, `non_fast_forward`,
`required_signatures`; pull_request allowed_merge_methods == `["merge"]`;
required-status-checks set (semantic diff, sorted by context) matches
the in-tree mirror.

Any change to the live ruleset must update both the mirror file AND
`docs/security/required-checks.md` in the same PR.
