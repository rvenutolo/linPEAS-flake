# Settings Posture — `rvenutolo/linPEAS-flake`

This document is the **source of truth** for every GitHub-side settings knob this repo depends on. Most rows are asserted by `scripts/check-settings-posture.sh` (each read from one of four `gh api` payloads); the tag-protection ruleset row is asserted by `scripts/check-tag-protection.sh`. The rest are manual-UI rows — the fork-PR approval gate, the merge-method flags, and maintainer 2FA — each called out where it appears and each unreachable by the drift check for one of the three reasons given under [Drift detection](#drift-detection). If a value drifts, treat it as a security incident.

## Security & analysis

| Setting                                  | Required value | Probe                                                                                                        |
| ---------------------------------------- | -------------- | ------------------------------------------------------------------------------------------------------------ |
| `secret_scanning.status`                 | `enabled`      | `gh api /repos/rvenutolo/linPEAS-flake --jq '.security_and_analysis.secret_scanning.status'`                 |
| `secret_scanning_push_protection.status` | `enabled`      | `gh api /repos/rvenutolo/linPEAS-flake --jq '.security_and_analysis.secret_scanning_push_protection.status'` |
| `dependabot_security_updates.status`     | `enabled`      | `gh api /repos/rvenutolo/linPEAS-flake --jq '.security_and_analysis.dependabot_security_updates.status'`     |

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

## Merge method (manual UI)

Settings → General → "Pull Requests" must match:

| Setting                  | Required value |
| ------------------------ | -------------- |
| `allow_merge_commit`     | `true`         |
| `allow_rebase_merge`     | `false`        |
| `allow_squash_merge`     | `false`        |
| `allow_auto_merge`       | `true`         |
| `allow_update_branch`    | `true`         |
| `delete_branch_on_merge` | `true`         |
| `merge_commit_title`     | `PR_TITLE`     |
| `merge_commit_message`   | `PR_BODY`      |

These flags appear on `GET /repos/{owner}/{repo}` but GitHub gates the
fields behind `contents: write` — i.e. push access. The `settings-drift-checker` App
([`docs/runbooks/settings-drift-app.md`](../runbooks/settings-drift-app.md))
is read-only by construction; granting `contents: write` would let its
installation token push arbitrary code, which is a far worse blast
radius than the settings-mutation it would unlock. So merge-method
posture is not API-probed.

Defence-in-depth instead: the `protect-main` ruleset's
`pull_request.allowed_merge_methods=["merge"]` rule
([`docs/security/required-checks.md`](required-checks.md)) rejects any
rebase/squash merge at push time regardless of the repo-level flags,
and `pr-title-lint` enforces the Conventional-Commits shape that
`merge_commit_title=PR_TITLE` relies on. A UI flip to enable
squash/rebase as a repo default does not silently land non-merge
commits on `main` — the ruleset rejects the merge. Drift on the
ruleset itself is caught by `scripts/check-protect-main.sh` via the
required `protect-main-drift-check` CI job in `ci.yml`, which probes
endpoints reachable with `Administration: Read`.

Rationale for the values: rebase + squash rewrite commits and break
GPG/SSH signatures on the rewritten objects. Merge-commit preserves
branch commits verbatim on `main`; the merge commit itself is
web-flow-signed by GitHub, so `required_signatures` is satisfied for
both the branch commits (signed by the author) and the merge commit.
`merge_commit_title=PR_TITLE` means the PR title is the merge-commit
subject — `pr-title-lint` enforces it as Conventional Commits.

## Environments

| Env            | Setting             | Required value | Probe                                                                                     |
| -------------- | ------------------- | -------------- | ----------------------------------------------------------------------------------------- |
| `github-pages` | `can_admins_bypass` | `false`        | `gh api /repos/rvenutolo/linPEAS-flake/environments/github-pages --jq .can_admins_bypass` |

## Tag-protection ruleset

| Setting                          | Required value                                                                                                                                                                                             | Probe                                                                               |
| -------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Ruleset `release-tag-protection` | exists, target `tag`, enforcement `active`, rules include `deletion` + `update` + `non_fast_forward`, `bypass_actors` empty, include pattern matches `refs/tags/[0-9]{8}-[0-9a-f]{7,40}` or `refs/tags/**` | `nix develop --command ./scripts/check-tag-protection.sh` (exit 0 = posture intact) |

## Maintainer account (manual)

- 2FA: **must be on**. Verify at <https://github.com/settings/security>. Not visible to `gh` CLI's OAuth scope.

## Drift detection

Every row above whose Probe column is a `gh api` invocation is enforced by `scripts/check-settings-posture.sh`, run from `.github/workflows/settings-posture-drift-check.yml` on a daily cron schedule (plus `workflow_dispatch` for manual probes). On mismatch the workflow opens a deduped `settings-drift` issue, which auto-closes when the next run sees the posture reconciled. The tag-protection ruleset row is the exception: it is enforced by `scripts/check-tag-protection.sh` via the `tag-protection-drift-check` required CI job, not by `scripts/check-settings-posture.sh`, which probes only the repo, Actions-permissions, workflow-permissions, and `github-pages` environment endpoints.

Manual-UI rows (fork-PR approval gate, maintainer 2FA, merge-method flags) are not covered — GitHub either exposes no REST endpoint, gates the field behind `contents: write` (push access) which the read-only `settings-drift-checker` App cannot hold, or keeps the field outside the token's visibility entirely (maintainer 2FA). Those rows are review-time + defence-in-depth checks (see the merge-method section above).

The endpoints this check probes require Administration:Read scope, which `secrets.GITHUB_TOKEN` cannot have. Auth is done via a dedicated read-only `settings-drift-checker` GitHub App; setup is documented at [`docs/runbooks/settings-drift-app.md`](../runbooks/settings-drift-app.md).

To probe manually from a developer shell (requires `gh auth login` with admin-read scope on the repo):

```bash
nix develop --command ./scripts/check-settings-posture.sh
```

Exits 0 on full match, 1 on any drift, and 2 when the comparison could
not be made at all — `gh` or `jq` is absent from PATH, a probed
endpoint could not be fetched, or a probed endpoint returned a payload
that is missing, unreadable, empty, not JSON, or carrying a field this
check reads at the wrong type. Every mismatched setting is logged to
stderr.
