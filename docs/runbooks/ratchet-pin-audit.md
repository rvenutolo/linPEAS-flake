# Ratchet pin audit runbook

The `ratchet-pin-audit` workflow runs on a daily cron (see
[CI — cron schedule](../architecture/ci.md#cron-schedule)). It runs
`ratchet lint` (from the devshell) against every workflow file under
`.github/workflows/` and re-derives the canonical SHA for each
SHA-pinned action ref. On *any* failure — detected drift, an upstream
API failure, a ratchet tool failure, or an unclassified error — the
workflow opens (or updates) a single deduped umbrella issue labeled
`ratchet-drift`, whose `Reason:` line names which of the four it was;
triage by that line using the sections below. The issue auto-closes on
the next clean run.

Two classes of upstream ref are skipped before any API call (a local
`./` action, which names no upstream, is dropped earlier). Each is
backed by a different PR-time check.

Floating-major pins (`# vN`) are skipped because such a tag retargets on
every release, so a benign move is indistinguishable from an attack.
Their integrity rests on the immutable digest pin, Renovate currency, and
the PR-time `check-pin-digest-provenance.sh` gate, which requires a
floating-major digest move to be reachable from the upstream default
branch — see [pin convention](../architecture/pin-convention.md).

This repo's own composite-action self-references are skipped because they
have no upstream tag to compare against: Renovate's `pinDigests` rule
tracks this repo's own `main` HEAD, not an upstream release. The
digest-provenance gate skips them for the same reason, so the PR-time
surface is `check-uses-sha-pinned.sh` alone, which still requires a full
40-hex SHA — see
[repo config](../security/repo-config.md).

This runbook is linked inline from the auto-filed issue body.

## Why this exists

`scripts/check-uses-sha-pinned.sh` enforces that every non-local
`uses:` ref is a full SHA. Renovate keeps those SHAs aligned with upstream
release tags. Neither mechanism catches the case where an action
publisher **force-moves a tag to a different SHA after we pinned to
it** — the tag-vs-pin drift attack. The per-ref re-derivation in this
workflow (`gh api …/git/refs/tags/{tag}`) is the detector for that
class; `ratchet lint` is a local pin-shape tripwire alongside it.

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
    find .github/workflows \
      \( -name '*.yml' -o -name '*.yaml' \) \
      -exec sed --in-place \
        's|<repo>@<old-sha>|<repo>@<new-sha>|g' {} +
    ```

    Both extensions are covered because GitHub Actions runs `*.yaml`
    workflows identically to `*.yml`, and the audit's own discovery
    globs both — a `*.yml`-only rewrite would leave a drifted pin in
    place and the next run would re-file the same issue.

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

The per-ref canonical-SHA re-derivation
(`gh api …/git/refs/tags/{tag}`) failed or rate-limited, or ratchet's
own output matched the upstream-failure heuristic. The `github.token`
is capped at 1,000 requests
per hour per repository; transient 5xx is also possible.

1. Re-run the workflow once via `workflow_dispatch`.
1. If it fails again with the same reason, check the
    [GitHub Status page](https://www.githubstatus.com/).
1. If the API is healthy, inspect the run log — the ratchet command
    may be hitting a different upstream (the action's own
    repository) that's rate-limited or down.

### `ratchet-tool-failure`

Ratchet exited non-zero (the per-ref re-derivation is skipped in that
case, so no drift is reported alongside); OR `classify-pin-ref.sh`
failed or returned an unrecognized verdict for a ref; OR a drift line
failed shape validation; OR the workflow glob matched zero files.

1. Inspect the run log; look at the raw ratchet stderr.
1. Look first for an unpinned-ref finding. `ratchet lint` exits
    non-zero on an unpinned `uses:` as readily as on a tool error, and
    `check-uses-sha-pinned.sh` should have blocked that at PR time —
    so a finding here means the PR gate was bypassed or skipped. Treat
    it as a gate failure, not a tool failure.
1. If ratchet instead started exiting non-zero on a workflow set it
    accepted before, most likely after a ratchet upgrade, bump ratchet
    locally via `nix flake update` and re-run. Drift itself comes from
    the per-ref `gh api` re-derivation rather than from ratchet's
    output, so an output-format change cannot fabricate a drift
    report.
1. The step does grep ratchet's output to tell an upstream failure
    from a tool failure, so a reworded ratchet error can still land an
    upstream failure under this reason. If the run log shows one,
    widen the heuristic grep in the `audit pins` step. The structural
    invariant `scripts/check-ratchet-pin-audit.sh` pins the four reason values
    the notify body documents (`drift-detected`,
    `upstream-api-failure`, `ratchet-tool-failure`, `unknown`), not
    the heuristic strings — so widening it is a single-file change.
1. If the workflow glob matched zero files, a refactor moved
    workflows out from under `.github/workflows/`. Adjust the glob
    in the `audit pins` step, keeping both `*.yml` and `*.yaml`
    covered — the audit fails closed on an empty match precisely so
    a narrowed glob surfaces here rather than passing green over an
    unscanned tree.

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

That version number is load-bearing, not incidental: it is what makes
the sentence above a claim about a specific tool version rather than a
permanent claim about ratchet in general. `ratchet` comes from nixpkgs
as a bare devShell entry with no pin in the tree, so it floats with the
`nixpkgs-unstable` input — the devShell is built from `pkgs-unstable` —
while this page and `ratchet-pin-audit.yml` assert a number.
`scripts/check-ratchet-pin-audit.sh` therefore compares every
`ratchet <X.Y.Z>` literal in both files against `ratchet --version` from
the devShell and fails on a mismatch. A lockfile refresh that changes
the version turns that check red, which is the prompt to re-read this
paragraph: if a later ratchet gains upstream API checks, the rationale
for the `gh api` re-derivation stops holding and the workflow's extra
work starts looking redundant. Dropping every literal instead of
updating it also fails, so removing the claim stays a decision rather
than a side effect.

`ratchet update` does reach upstream, but it only operates on pins
written in ratchet's own annotation format
(`uses: foo@<sha> # ratchet:foo@v3`). Our pins use plain
`# v3` trailing comments and are therefore invisible to
`ratchet update`. Remediation must be done by hand (or via Renovate
on its next scheduled run).

## Related

- Adjacent watchdog: `stale-pin-check.yml` (`pin-stalled` label)
- Underlying enforcer: `scripts/check-uses-sha-pinned.sh`
- Structural invariant: `scripts/check-ratchet-pin-audit.sh`
