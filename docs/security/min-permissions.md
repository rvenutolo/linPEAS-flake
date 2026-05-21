# GITHUB_TOKEN permissions posture

Strict least-privilege rule for every workflow in `.github/workflows/`.

## Invariants

1. **Top-level `permissions:` is the empty map `{}`.** No scopes are granted at workflow scope; every scope must be declared per-job.
1. **Every job declares its own `permissions:` block.** Inheritance from the (empty) top is not allowed; an omitted block fails the lint.
1. **No `read-all` / `write-all` / scalar permissions form at top.** Subsumed by rule 1 but reported with a clearer message when the input is one of those forms.

## Why

`GITHUB_TOKEN`'s default scope set is broad. Reviewer-only enforcement is fragile — a workflow added without an explicit `permissions:` block silently inherits repo defaults and breaks least-privilege posture. Locking every job to an explicit, narrowly-scoped block keeps the blast radius of a compromised step bounded to scopes that job actually needs.

## Enforcement

`scripts/check-min-permissions.sh` parses every workflow with `yq` and rejects:

- top-level `permissions:` missing, non-empty map, or scalar (`read-all` / `write-all`)
- any job whose `permissions:` block is omitted or not a map

Wired as the `min-permissions` required CI job and as a pre-commit hook.

## Adding a workflow or job

- Set top-level `permissions: {}` in the new workflow.
- For each new job, add a `permissions:` block listing only the scopes that job needs. If the job does nothing more than checkout + run scripts on a public repo, `contents: read` is sufficient; for ghcr push, `packages: write`; for attestations, `id-token: write` + `attestations: write`; etc.

The lint catches the posture violation at pre-commit time; CI catches it on PR. Either way, the missing block is surfaced before merge.
