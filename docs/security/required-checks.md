# Required Status Checks — main branch

Snapshot of `gh api repos/rvenutolo/linPEAS-flake/branches/main/protection`
as of 2026-05-17. Update this file in the same change as any modification
to branch protection.

## Required contexts

| Context                  | Source workflow | Source file              |
|--------------------------|-----------------|--------------------------|
| flake-check              | ci              | .github/workflows/ci.yml |
| build-linpeas            | ci              | .github/workflows/ci.yml |
| smoke-test               | ci              | .github/workflows/ci.yml |
| build-linpeas-arm64      | ci              | .github/workflows/ci.yml |
| smoke-test-arm64         | ci              | .github/workflows/ci.yml |
| image-smoke              | ci              | .github/workflows/ci.yml |
| image-smoke-arm64        | ci              | .github/workflows/ci.yml |
| bundle-smoke             | ci              | .github/workflows/ci.yml |
| dashboard-data-tests     | ci              | .github/workflows/ci.yml |
| required-checks-no-paths | ci              | .github/workflows/ci.yml |
| pr-workflows-no-secrets  | ci              | .github/workflows/ci.yml |
| tag-protection-drift-check | ci            | .github/workflows/ci.yml |
| renovate-invariants        | ci            | .github/workflows/ci.yml |

## Invariant (AU-P-2)

No workflow listed above may declare `paths:` or `paths-ignore:` under its
`on.pull_request:` trigger. Such a filter creates the auto-merge
path-filter trap: PRs that touch only filtered-out paths skip the check
entirely, and `gh pr merge --auto --squash` would merge them with reduced
coverage.

Enforced by `scripts/check-required-checks-no-paths.sh`, wired as the
`required-checks-no-paths` job in `ci.yml`. That job itself is in the
required-check list above, so the enforcement is self-bootstrapping
(no PR can land on `main` while the lint is red).

## Maintenance

When branch protection's required-check list changes:

1. Update the table above to match.
2. If a new workflow file appears in column 3, verify it does not declare
   `paths:` / `paths-ignore:` under `pull_request:`. The lint will catch
   this on PR, but the doc must reflect reality.
3. Use `gh api repos/rvenutolo/linPEAS-flake/branches/main/protection/required_status_checks/contexts`
   to read the current list.
