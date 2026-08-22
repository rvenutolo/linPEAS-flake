# Docs correctness audit

Freshness gates (`*-fresh`) validate only the bodies of generated blocks.
Nothing generates hand-written prose about CI, so a sentence naming a job
that does not exist passes every gate in the repo. A reading agent is the
only mechanism that catches that class of drift.

The `docs-audit-reminder` workflow decides when running one is worth the
effort, and the `docs-audit-state` marker is what makes its signal mean
something.

## Running an audit

Invoke the `/docs-audit` slash command. It is read-only: it emits one
severity-ranked findings report and edits nothing. Fix what it finds in
the normal PR flow.

## Closing the loop

The final fix PR of an audit cycle records the audit point:

```bash
just docs-audit-done
git add .github/docs-audit-state
```

That writes the current commit into `.github/docs-audit-state`.
`scripts/docs-audit-pressure.sh` diffs CI structure from there, so the
number it reports means *commits nobody has audited yet* — zero right
after an audit, growing only with unreviewed churn.

Run it when the findings are fixed, not when the audit is dispatched. The
monthly reminder issue closes on the count this produces; marking at
dispatch time would close the issue over findings still outstanding.

If an audit finds nothing, mark immediately — a clean read is still a
read, and the churn it covered has been audited.

## Why a marker rather than a rolling window

A fixed-length window measures churn the maintainer has already read.
On a repo with a steady commit rate that count never falls to zero, so a
reminder issue whose close condition reads the count can never close
itself — it becomes a manual-close issue wearing an automatic-close
condition, and an issue that always needs closing by hand trains the
maintainer to close it without reading it.

Measuring from the recorded audit point makes zero reachable, and makes a
non-zero number an actual quantity of unreviewed change.

## Forgetting to mark

Nothing enforces the marker, and nothing needs to: an audit whose point
was never recorded leaves pressure climbing, which is the correct signal
for an audit that never happened. The failure mode is a reminder that
keeps reminding, not a silent pass.

## When the marker cannot be read

`scripts/docs-audit-pressure.sh` exits 2 — could-not-run — when the file
is absent, carries no `LAST_AUDIT_SHA=<40-hex>` line, or names a commit
this history does not contain (a rewritten history, or a shallow clone).
It never falls back to a window: a fallback base still prints a
`PRESSURE` line, and the reminder workflow would file that number as
though it had been measured from the audit point it names.

That exit reddens the monthly job, which is the intended behavior for a
genuine failure. Non-zero pressure, by contrast, always exits 0 — a
workflow that goes red during normal CI churn trains the maintainer to
ignore red.
