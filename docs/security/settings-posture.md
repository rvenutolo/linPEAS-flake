# Settings Posture — `rvenutolo/linPEAS-flake`

This document is the **source of truth** for every GitHub-side settings knob this repo depends on. Every row is verifiable by a single `gh api` query. If a value drifts, treat it as a security incident.

## Security & analysis

| Setting                                        | Required value                                                                                      | Probe                                                                                                              |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `secret_scanning.status`                       | `enabled`                                                                                           | `gh api /repos/rvenutolo/linPEAS-flake --jq '.security_and_analysis.secret_scanning.status'`                       |
| `secret_scanning_push_protection.status`       | `enabled`                                                                                           | `gh api /repos/rvenutolo/linPEAS-flake --jq '.security_and_analysis.secret_scanning_push_protection.status'`       |
| `secret_scanning_non_provider_patterns.status` | `enabled` (residual — API silently ignores PATCH on personal accounts; probe will show `disabled`.) | `gh api /repos/rvenutolo/linPEAS-flake --jq '.security_and_analysis.secret_scanning_non_provider_patterns.status'` |
| `secret_scanning_validity_checks.status`       | `enabled` (residual — same API limitation as above.)                                                | `gh api /repos/rvenutolo/linPEAS-flake --jq '.security_and_analysis.secret_scanning_validity_checks.status'`       |
| `dependabot_security_updates.status`           | `enabled`                                                                                           | `gh api /repos/rvenutolo/linPEAS-flake --jq '.security_and_analysis.dependabot_security_updates.status'`           |

## Actions permissions

| Setting                            | Required value                                      | Probe                                                                                                       |
| ---------------------------------- | --------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `allowed_actions`                  | `selected` (per `docs/security/allowed-actions.md`) | `gh api /repos/rvenutolo/linPEAS-flake/actions/permissions --jq .allowed_actions`                           |
| `sha_pinning_required`             | `true`                                              | `gh api /repos/rvenutolo/linPEAS-flake/actions/permissions --jq .sha_pinning_required`                      |
| `default_workflow_permissions`     | `read`                                              | `gh api /repos/rvenutolo/linPEAS-flake/actions/permissions/workflow --jq .default_workflow_permissions`     |
| `can_approve_pull_request_reviews` | `false`                                             | `gh api /repos/rvenutolo/linPEAS-flake/actions/permissions/workflow --jq .can_approve_pull_request_reviews` |

### Fork-PR approval gate (manual UI)

Settings → Actions → General → "Fork pull request workflows from outside
collaborators" must be set to **"Require approval for first-time
contributors"**. No REST endpoint exposes this knob; verify in the
browser. Outside contributor PRs queue until the maintainer clicks
**Approve and run** — prevents arbitrary fork pushes from consuming
Actions resources without review.

## Merge method

| Setting                  | Required value | Probe                                                                |
| ------------------------ | -------------- | -------------------------------------------------------------------- |
| `allow_merge_commit`     | `true`         | `gh api /repos/rvenutolo/linPEAS-flake --jq .allow_merge_commit`     |
| `allow_rebase_merge`     | `false`        | `gh api /repos/rvenutolo/linPEAS-flake --jq .allow_rebase_merge`     |
| `allow_squash_merge`     | `false`        | `gh api /repos/rvenutolo/linPEAS-flake --jq .allow_squash_merge`     |
| `allow_auto_merge`       | `true`         | `gh api /repos/rvenutolo/linPEAS-flake --jq .allow_auto_merge`       |
| `allow_update_branch`    | `true`         | `gh api /repos/rvenutolo/linPEAS-flake --jq .allow_update_branch`    |
| `delete_branch_on_merge` | `true`         | `gh api /repos/rvenutolo/linPEAS-flake --jq .delete_branch_on_merge` |
| `merge_commit_title`     | `PR_TITLE`     | `gh api /repos/rvenutolo/linPEAS-flake --jq .merge_commit_title`     |
| `merge_commit_message`   | `PR_BODY`      | `gh api /repos/rvenutolo/linPEAS-flake --jq .merge_commit_message`   |

Rationale: rebase + squash rewrite commits and break GPG/SSH signatures
on the rewritten objects. Merge-commit preserves branch commits verbatim
on `main`; the merge commit itself is web-flow-signed by GitHub, so
`required_signatures` is satisfied for both the branch commits (signed by
the author) and the merge commit. `merge_commit_title=PR_TITLE` means
the PR title is the merge-commit subject — `pr-title-lint` enforces it
as Conventional Commits.

## Environments

| Env            | Setting             | Required value | Probe                                                                                     |
| -------------- | ------------------- | -------------- | ----------------------------------------------------------------------------------------- |
| `github-pages` | `can_admins_bypass` | `false`        | `gh api /repos/rvenutolo/linPEAS-flake/environments/github-pages --jq .can_admins_bypass` |

## Tag-protection ruleset

| Setting                                                                                                                                                                                                                   | Required value                                            | Probe                                                                               |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Ruleset name `release-tag-protection` exists, target `tag`, enforcement `active`, rules include `deletion` + `update` + `non_fast_forward`, include pattern matches `refs/tags/[0-9]{8}-[0-9a-f]{7,40}` or `refs/tags/**` | `gh api /repos/rvenutolo/linPEAS-flake/rulesets` + filter | `nix develop --command ./scripts/check-tag-protection.sh` (exit 0 = posture intact) |

## Maintainer account (manual)

- 2FA: **must be on**. Verify at <https://github.com/settings/security>. Not visible to `gh` CLI's OAuth scope.
