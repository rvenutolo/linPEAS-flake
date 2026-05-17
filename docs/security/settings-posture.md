# Settings Posture — `rvenutolo/linPEAS-flake`

This document is the **source of truth** for every GitHub-side settings knob this repo depends on. Every row is verifiable by a single `gh api` query. If a value drifts, treat it as a security incident.

## Security & analysis

| Setting | Required value | Probe |
|---|---|---|
| `secret_scanning.status` | `enabled` | `gh api /repos/rvenutolo/linPEAS-flake --jq '.security_and_analysis.secret_scanning.status'` |
| `secret_scanning_push_protection.status` | `enabled` | `gh api /repos/rvenutolo/linPEAS-flake --jq '.security_and_analysis.secret_scanning_push_protection.status'` |
| `secret_scanning_non_provider_patterns.status` | `enabled` | `gh api /repos/rvenutolo/linPEAS-flake --jq '.security_and_analysis.secret_scanning_non_provider_patterns.status'` |
| `secret_scanning_validity_checks.status` | `enabled` | `gh api /repos/rvenutolo/linPEAS-flake --jq '.security_and_analysis.secret_scanning_validity_checks.status'` |
| `dependabot_security_updates.status` | `enabled` | `gh api /repos/rvenutolo/linPEAS-flake --jq '.security_and_analysis.dependabot_security_updates.status'` |

## Actions permissions

| Setting | Required value | Probe |
|---|---|---|
| `sha_pinning_required` | `true` | `gh api /repos/rvenutolo/linPEAS-flake/actions/permissions --jq .sha_pinning_required` |
| `default_workflow_permissions` | `read` | `gh api /repos/rvenutolo/linPEAS-flake/actions/permissions/workflow --jq .default_workflow_permissions` |
| `can_approve_pull_request_reviews` | `false` | `gh api /repos/rvenutolo/linPEAS-flake/actions/permissions/workflow --jq .can_approve_pull_request_reviews` |

`allowed_actions` is intentionally **not pinned here** in P1. It is covered by GAP-4 / P3.

## Environments

| Env | Setting | Required value | Probe |
|---|---|---|---|
| `github-pages` | `can_admins_bypass` | `false` | `gh api /repos/rvenutolo/linPEAS-flake/environments/github-pages --jq .can_admins_bypass` |

## Maintainer account (manual)

- 2FA: **must be on**. Verify at <https://github.com/settings/security>. Not visible to `gh` CLI's OAuth scope.
