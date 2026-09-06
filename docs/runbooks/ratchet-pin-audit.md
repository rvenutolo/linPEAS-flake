# Ratchet pin audit runbook

The `ratchet-pin-audit` workflow runs on a daily cron (see
[CI — cron schedule](../architecture/ci.md#cron-schedule)). It runs
`ratchet lint` (from the devshell) against every workflow file under
`.github/workflows/` and re-derives the canonical SHA for each
SHA-pinned action ref carrying a trailing `# <tag>` comment that it does not skip
(see below). On *any* failure —
detected drift, an upstream API failure, a ratchet tool failure, an
unclassified error, or a cancelled run — the workflow opens a single
deduped umbrella issue labeled `ratchet-drift`, or comments on an
already-open one. The issue body's `Reason:` line names the reason of the
run that opened it; a later failure's comment carries only the run
link (a later cancelled run's comment says it was cancelled), so when
the issue has been re-commented, read the newest run's log for its
reason. Match the reason against the sections below. The issue
auto-closes on the next clean run.

Two classes of upstream ref are skipped before any API call (a local
`./` action, which names no upstream, is dropped earlier). Each still
has a PR-time backstop, described below.

Floating-major pins (`# vN`) are skipped because such a tag retargets on
every release, so a benign move is indistinguishable from an attack.
Their integrity rests on the immutable digest pin, Renovate currency, and
the PR-time `check-pin-digest-provenance.sh` gate, which requires a
floating-major digest move to be reachable from the upstream default
branch — see [pin convention](../architecture/pin-convention.md).

This repo's own composite-action self-references are skipped because they
have no upstream tag to compare against: Renovate's `pinDigests` rule
tracks this repo's own `main` HEAD, not an upstream release. The
digest-provenance gate skips them for the same reason, so their PR-time
backstop is `check-uses-sha-pinned.sh` (the `uses-sha-pinned` member of
`lint-workflow-security`), backing the GitHub-side `sha_pinning_required`
setting and still requiring a full 40-hex SHA — see
[repo config](../security/repo-config.md). `check-patch-tag-pins.sh` also
reads these lines and demands a versioned `# vX.Y[.Z]` tag, but against
the tree it runs only as the `patch-tag-pins` pre-commit hook and gates no
merge (its fixture tests do run in `harness-group`) — see
[pin convention](../architecture/pin-convention.md); this repo publishes
no release tags on its composite actions, so its self-reference carries an
inline `# patch-tag-exception:` marker.

This runbook is linked inline from the auto-filed issue body.

## Why this exists

`scripts/check-uses-sha-pinned.sh` enforces that every non-local
`uses:` ref is a full SHA. Renovate keeps those SHAs aligned with upstream
release tags. Neither mechanism catches the case where an action
publisher **force-moves a tag to a different SHA after we pinned to
it** — the tag-vs-pin drift attack. The per-ref re-derivation in this
workflow — a `gh api …/git/refs/tags/{tag}` lookup, dereferenced through
`…/git/tags/{sha}` when the tag is annotated — is the detector for that
class; `ratchet lint` is a local pin-shape tripwire alongside it.

## Triage by reason

The auto-filed issue body includes a `Reason:` line. Match it
against the sections below.

### `drift-detected`

At least one drifted ref is listed in the body of the issue as it was
opened, one per line, in the shape `<ref>@<tag> pinned=<sha> canonical=<sha>`,
where `<ref>` is the literal pinned action — a monorepo action keeps its
subpath, as in `github/codeql-action/analyze`.

Steps:

1. For each drifted ref, open the upstream release notes for `tag`
    on `owner/repo`. Confirm the publisher describes a re-tag /
    re-release.

1. **If the re-tag is legitimate** (publisher acknowledges it, the
    diff between `pinned` and `canonical` matches their stated
    change): update each drifted pin in place. Replace the old
    `pinned` SHA with the `canonical` SHA from the issue body across
    every workflow file and composite action that uses it — the audit
    scans only `.github/workflows/`, so a composite under
    `.github/actions/` carrying the same pin is not in the issue body
    and would otherwise keep the old SHA:

    ```shell
    find .github/workflows .github/actions \
      \( -name '*.yml' -o -name '*.yaml' \) \
      -exec sed --in-place \
        's|<repo>@<old-sha>|<repo>@<new-sha>|g' {} +
    ```

    Both extensions are covered because GitHub Actions runs `*.yaml`
    workflows identically to `*.yml`, and the audit's own discovery
    globs both — a `*.yml`-only rewrite would leave a drifted pin in
    place and the next run would re-file the same issue.

    Review the diff, open a PR. (`ratchet update` is not used here
    because our pins use plain `# v3.36.0`-style trailing-comment annotations
    rather than ratchet's `# ratchet:repo@v3.36.0` format, so ratchet
    does not recognize them as ratchet-managed.)

    That PR fails the required `lint-doc-invariants` job by design: a
    SHA that moves under an unchanged version comment is the
    digest-repoint class `check-pin-digest-provenance.sh` hard-fails.
    Move the version label together with the SHA, or update the pin
    to the corrected upstream release — see
    [pin digest provenance](../security/repo-config.md#pin-digest-provenance).
    A Renovate digest-only bump for the same ref hits the same gate, so
    waiting for Renovate helps only when upstream also published a new
    version label.

1. **If the release notes do not describe the SHA change**: treat
    this as a potential supply-chain event. Do not auto-update.
    Escalate (open a security advisory, file an upstream issue) and
    keep the existing pin until the situation is resolved.

### `upstream-api-failure`

One of the per-ref canonical-SHA re-derivation's API calls — the
`gh api …/git/refs/tags/{tag}` lookup, or the `…/git/tags/{sha}`
dereference an annotated tag needs — failed, rate-limited, or returned a
ref payload `jq` could not read a SHA and object type from (the
annotated-tag dereference fails on a non-zero call or an empty SHA); or
ratchet's own output matched the upstream-failure heuristic. The
`github.token` is
capped at 1,000 requests per hour per repository; transient 5xx is also
possible.

1. Re-run the workflow once via `workflow_dispatch`.
1. If it fails again with the same reason, check the
    [GitHub Status page](https://www.githubstatus.com/).
1. If the API is healthy, inspect the run log. The audit stops at the
    first failure, so the log carries one failure line: it names the
    `owner/repo@tag` whose lookup, dereference or payload parse failed,
    quoting the payload when one was read (a failure routed here by the
    ratchet heuristic quotes ratchet's output instead and names no ref).
    A named ref that keeps failing across re-runs points at that action's
    repository — renamed, made private, or its tag deleted — rather
    than at the API as a whole; the refs after it were not attempted.

### `ratchet-tool-failure`

Ratchet exited non-zero (the per-ref re-derivation is skipped in that
case, so no drift is reported alongside); OR `classify-pin-ref.sh`
failed or returned an unrecognized verdict for a ref; OR a drift line
failed shape validation; OR the workflow glob matched zero files.

1. Inspect the run log; look at the `ratchet exit N; raw output:`
    block, which is ratchet's combined stdout and stderr.
1. Look first for an unpinned-ref finding. `ratchet lint` exits
    non-zero on an unpinned `uses:` as readily as on a tool error, and
    `check-uses-sha-pinned.sh` should have blocked that at PR time —
    so a finding here means the PR gate was bypassed or skipped. Treat
    it as a gate failure, not a tool failure.
1. If ratchet instead started exiting non-zero on a workflow set it
    accepted before, most likely after a ratchet upgrade, bump the
    `nixpkgs-unstable` input that ships ratchet
    (`nix flake update nixpkgs-unstable`), update every
    `ratchet <X.Y.Z>` literal in this page and in the workflow to the
    version the refreshed devShell reports — `check-ratchet-pin-audit.sh`,
    run by the required `harness-group` job, fails on a stale literal (see
    [Note on ratchet's role](#note-on-ratchets-role)) — and re-run. Drift
    itself comes from the per-ref `gh api` re-derivation rather than from
    ratchet's output, so a change in ratchet's output format cannot
    fabricate a drift report.
1. The step tells an upstream failure from a tool failure with a fixed
    heuristic grep over ratchet's output, so a reworded ratchet error
    can still land an upstream failure under this reason. If the run
    log shows one, widen the heuristic grep in the `audit pins` step.
    The structural invariant `scripts/check-ratchet-pin-audit.sh` pins
    the four reason values the notify body documents (`drift-detected`,
    `upstream-api-failure`, `ratchet-tool-failure`, `unknown`), not
    the heuristic strings — so widening it is a single-file change.
1. If the workflow glob matched zero files, a refactor moved
    workflows out from under `.github/workflows/`. Adjust the glob
    in the `audit pins` step, keeping both `*.yml` and `*.yaml`
    covered — the audit fails closed on an empty match precisely so
    a narrowed glob surfaces here rather than passing green over an
    unscanned tree.

### `unknown`

The `check` job produced no `reason=` output. Three run shapes do
that: the `audit pins` step exited non-zero on an unhandled error
inside its run block; a step before it failed, so the audit never ran;
or the run was cancelled — most often its `timeout-minutes` was
exceeded. The notify composite flags a
cancelled run as an infrastructure failure rather than a finding: with
a `[!WARNING]` banner at the top of the issue body when the cancelled
run is the one that opened the issue, and in its comment when it
re-commented an already-open one. Look for that flag first: a
cancelled run says nothing about pin drift, so re-run it. For a failed
earlier step, read its log and re-run once it is fixed; it says nothing
about pin drift either. For an unhandled error, inspect the run log
directly, add classification for the new failure mode, and update both
the workflow and this runbook.

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
detection via per-ref canonical-SHA re-derivation: a
`gh api repos/{owner}/{repo}/git/refs/tags/{tag}` lookup, dereferenced
through `…/git/tags/{sha}` when the tag is annotated.

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
(`uses: foo@<sha> # ratchet:foo@v3.36.0`). Our pins use plain
`# v3.36.0`-style trailing comments and are therefore invisible to
`ratchet update`. Remediation must be done by hand; a Renovate
digest-only bump hits the digest-provenance gate — see the
`drift-detected` steps above.

## Related

- Adjacent watchdog: `stale-pin-check.yml` (`pin-stalled` label)
- Underlying enforcer: `scripts/check-uses-sha-pinned.sh`
- Structural invariant: `scripts/check-ratchet-pin-audit.sh`
