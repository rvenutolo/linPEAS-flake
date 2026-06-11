# Ratchet Pin Audit Runbook

The `ratchet-pin-audit` workflow runs daily at 09:15 UTC. It invokes
`sethvargo/ratchet check` against every workflow file under
`.github/workflows/` and re-derives the canonical SHA for each
SHA-pinned action ref. When any pinned SHA no longer matches the
canonical SHA its tag now resolves to, the workflow opens (or
updates) a single deduped umbrella issue labeled `ratchet-drift`.
The issue auto-closes on the next clean run.

This runbook is linked inline from the auto-filed issue body.

## Why this exists

`scripts/check-uses-sha-pinned.sh` enforces that every `uses:` ref
is a full SHA. Renovate keeps those SHAs aligned with upstream
release tags. Neither mechanism catches the case where an action
publisher **force-moves a tag to a different SHA after we pinned to
it** — the tag-vs-pin drift attack. Ratchet is the canonical
detector for that class.

## Triage by reason

The auto-filed issue body includes a `Reason:` line. Match it
against the sections below.

### `drift-detected`

At least one drifted ref is listed in the issue body, one per line,
in the shape `owner/repo@tag pinned=<sha> canonical=<sha>`.

Steps:

1. For each drifted ref, open the upstream release notes for `tag`
    on `owner/repo`. Confirm the publisher describes a re-tag /
    re-release.

1. **If the re-tag is legitimate** (publisher acknowledges it, the
    diff between `pinned` and `canonical` matches their stated
    change): update each drifted pin in place. Replace the old
    `pinned` SHA with the `canonical` SHA from the issue body across
    every workflow file that uses the action:

    ```shell
    sed --in-place \
      's|<repo>@<old-sha>|<repo>@<new-sha>|g' \
      .github/workflows/*.yml
    ```

    Review the diff, open a PR. (`ratchet update` is not used here
    because our pins use plain `# v3` trailing-comment annotations
    rather than ratchet's `# ratchet:repo@v3` format, so ratchet
    does not recognize them as ratchet-managed.) Renovate will pick
    these up on its next scheduled run if you prefer to wait.

1. **If the release notes do not describe the SHA change**: treat
    this as a potential supply-chain event. Do not auto-update.
    Escalate (open a security advisory, file an upstream issue) and
    keep the existing pin until the situation is resolved.

### `upstream-api-failure`

The GitHub API call inside ratchet (or the per-ref re-derivation)
failed or rate-limited. The `github.token` authenticates at 5000
requests/hour; transient 5xx is also possible.

1. Re-run the workflow once via `workflow_dispatch`.
1. If it fails again with the same reason, check the
    [GitHub Status page](https://www.githubstatus.com/).
1. If the API is healthy, inspect the run log — the ratchet command
    may be hitting a different upstream (the action's own
    repository) that's rate-limited or down.

### `ratchet-tool-failure`

Ratchet exited non-zero but the per-ref re-derivation could not
reproduce any drift; OR a drift line failed shape validation; OR
the workflow glob matched zero files.

1. Inspect the run log; look at the raw ratchet stderr.
1. If ratchet's output format changed (most likely cause after a
    ratchet upgrade), bump ratchet locally via
    `nix flake update` and adapt the parser in
    `.github/workflows/ratchet-pin-audit.yml` (the `audit pins`
    step). The structural invariant
    `scripts/check-ratchet-pin-audit.sh` pins the four `reason=`
    tokens, not the heuristic strings — so updating heuristics is
    a single-file change.
1. If the workflow glob matched zero files, a refactor moved
    workflows out from under `.github/workflows/`. Adjust the glob
    in the `audit pins` step.

### `unknown`

The check step exited non-zero without writing a `result=` output.
Inspect the run log directly; this typically indicates an
unhandled error inside the run block. Add classification for the
new failure mode and update both the workflow and this runbook.

## Recovery

Once the underlying drift is resolved (pins updated, PR merged) or
the transient API failure clears, the next daily run will see
`result=success` and the `ratchet-drift` issue auto-closes via the
`notify-workflow-result` composite.

## Note on ratchet's role

ratchet 0.11.4 `check`/`lint` performs local pin-shape verification
only — it does not contact upstream APIs and cannot detect
tag-vs-SHA drift on its own. The workflow uses ratchet as a
belt-and-suspenders tripwire and performs the actual drift
detection via per-ref `gh api repos/{owner}/{repo}/git/refs/tags/{tag}`
canonical-SHA re-derivation.

`ratchet update` does reach upstream, but it only operates on pins
written in ratchet's own annotation format
(`uses: foo@<sha> # ratchet:foo@v3`). Our pins use plain
`# v3` trailing comments and are therefore invisible to
`ratchet update`. Remediation must be done by hand (or via Renovate
on its next scheduled run).

## Related

- Issue that introduced this: #161
- Adjacent watchdog: `stale-pin-check.yml` (`pin-stalled` label)
- Underlying enforcer: `scripts/check-uses-sha-pinned.sh`
- Structural invariant: `scripts/check-ratchet-pin-audit.sh`
