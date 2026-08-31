# SCORECARD_PAT rotation runbook

The `scorecard-drift-check.yml` workflow calls the OSSF Scorecard
CLI against this repo. The `Webhooks` check requires a scope
(`admin:repo_hook` read) that is not grantable via the workflow-level
`GITHUB_TOKEN` permissions block, so a fine-grained PAT is stored as
the repo secret `SCORECARD_PAT` and consumed via the `GITHUB_AUTH_TOKEN`
env var on the scorecard step.

This runbook is the durable record of how to create and rotate that PAT.

## When to rotate

- Annually, on or before the PAT's recorded expiry (max 1 year from creation).
- Immediately on suspected compromise.
- Immediately on revocation by GitHub (the scorecard logs then show `401`/`403`).

## Required PAT shape

- **Type:** fine-grained personal access token (not classic).
- **Owner:** `rvenutolo`.
- **Repository access:** Only select repositories → `rvenutolo/linPEAS-flake`.
- **Expiration:** 1 year maximum.
- **Repository permissions (all Read-only):**
    - Contents — for `Security-Policy`, `License`, `SBOM`, etc.
    - Metadata — mandatory (auto-selected)
    - Webhooks — for `Webhooks` check
- **Account permissions:** none.

## Create the token

1. GitHub → top-right avatar → **Settings** → **Developer settings** → **Personal access tokens** → **Fine-grained tokens** → **Generate new token**.
1. Name: `linpeas-flake-scorecard-drift-check`.
1. Expiration: 1 year from today.
1. Resource owner: `rvenutolo`.
1. Repository access: Only select repositories → `linPEAS-flake`.
1. Repository permissions: as listed above.
1. **Generate token** — copy the `github_pat_…` string immediately; GitHub never re-displays it.

## Store the token

1. Repo → **Settings** → **Secrets and variables** → **Actions** → **Repository secrets**.
1. If updating: select existing `SCORECARD_PAT` → **Update secret** → paste new value → **Update secret**.
1. If creating: **New repository secret** → name `SCORECARD_PAT` → paste value → **Add secret**.

## Verify

```bash
gh workflow run scorecard-drift-check.yml
gh run watch
```

Expected: green run, or red run with the `scorecard-drift` tracking issue surfacing real findings (not auth errors). If logs show `401`, `403`, or `Resource not accessible by personal access token`, the PAT permissions are wrong — return to "Required PAT shape" and recreate.

## Calendar reminder

After every rotation, set a personal reminder for **11 months out** to begin the next rotation cycle.
