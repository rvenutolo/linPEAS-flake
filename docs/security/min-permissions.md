# GITHUB_TOKEN permissions posture

Strict least-privilege rule for every workflow in `.github/workflows/`.

## Invariants

1. **Top-level `permissions:` is the empty map `{}`.** No scopes are granted at workflow scope; every scope must be declared per-job.
1. **Every job declares its own `permissions:` block.** Inheritance from the (empty) top is not allowed; an omitted block fails the lint.
1. **No scalar or list top-level `permissions:` (`read-all` / `write-all`, or a sequence).** Subsumed by rule 1, but reported with a clearer message when the input is one of those shapes.

## Why

`GITHUB_TOKEN`'s default scope set is broad. Reviewer-only enforcement is fragile — a workflow added without an explicit `permissions:` block silently inherits repo defaults and breaks least-privilege posture. Locking every job to an explicit, narrowly-scoped block keeps the blast radius of a compromised step bounded to scopes that job actually needs.

## Enforcement

`scripts/check-min-permissions.sh` parses every workflow with `yq` and rejects:

- top-level `permissions:` missing, non-empty map, scalar (`read-all` / `write-all`), or any other shape such as a list
- any job whose `permissions:` block is omitted or not a map

Wired as the `lint-workflow-security` CI job (member check `min-permissions`) and as a pre-commit hook.

## Per-job write-scope allowlist

`min-permissions` guarantees every job declares an explicit scope block,
but it does not constrain *which* write scopes a block may grant. A
hand-maintained allowlist closes that gap: `.github/permission-scopes.yml`
pins, per job, exactly the `write`-valued scopes that job is permitted to
hold. Widening a job's write surface means editing the allowlist, which
makes every such change a reviewable, security-relevant diff.

### Format

The allowlist is a per-job YAML map: workflow filename → job id → a sorted
list of permitted write-scope **names** (only the scope lists are
order-checked):

```yaml
example-workflow.yml:
  build: [attestations, contents, id-token]
  notify: [issues]
```

Only scope *names* whose value is `write` are listed. Read scopes (and
`none`) are unconstrained — they carry no least-privilege risk, so they
need no entry, and a job with no write scopes is omitted entirely.

### Enforcement

`scripts/check-permission-scopes.sh` cross-checks the live workflows
against the allowlist in both directions and fails on any of:

- **Over-grant** — a job grants a `write` scope that is not listed for
    that job in the allowlist. The token a compromised step could wield
    exceeds what was reviewed.
- **Stale entry** — the allowlist lists a write scope the job no longer
    grants, or names a workflow or job that no longer exists. Stale entries
    rot the allowlist into a misleading record of the actual write surface.
- **Unsorted scope list** — a job's scope list departs from sorted
    order, which keeps allowlist diffs minimal and duplicate-prone
    append-anywhere edits out.

Wired into the `lint-workflow-security` CI group and as the
`permission-scopes` pre-commit hook.

## Adding a workflow or job

- Set top-level `permissions: {}` in the new workflow.
- For each new job, add a `permissions:` block listing only the scopes that job needs. If the job does nothing more than checkout + run scripts on a public repo, `contents: read` is sufficient; for ghcr push, `packages: write`; for attestations, `id-token: write` + `attestations: write`; etc.

The lint catches the posture violation at pre-commit time; CI catches it on PR. Either way, the missing block is surfaced before merge.
