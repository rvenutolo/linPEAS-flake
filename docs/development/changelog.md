# Changelog generation

`CHANGELOG.md` is generator-owned. Manual edits are a review-blocker;
every change is overwritten on the next run. Maintain `cliff.toml` to
influence output, not the file directly.

## Tool

[git-cliff](https://git-cliff.org/) generates `CHANGELOG.md` from
conventional commits between release tags. Per the `nix-run-pinned`
invariant, git-cliff is invoked only via the flake-pinned package — not
an unpinned `nix run nixpkgs#git-cliff`. CI uses:

```sh
nix shell .#git-cliff --command git-cliff --config cliff.toml --output CHANGELOG.md
```

The same command works locally for manual rebuilds.

## When the job runs

The changelog job runs as part of `release-on-bump.yml`, triggered on
every push to `main` that changes `linpeas-pin.json`. It also runs on
`workflow_dispatch` (see Recovery below). A changelog failure does not
block image publication — the job runs after the `release` and
`manifest` jobs (and so, transitively, after both image builds), so a
transient cliff error cannot prevent the OCI image from shipping.

## App identity

The changelog commit is pushed using the same `linpeas-flake-bumper`
GitHub App identity that `update-linpeas.yml`'s `push-and-merge` job
uses: `BUMP_APP_CLIENT_ID` + `BUMP_APP_PRIVATE_KEY`. No new secret
surface is introduced.

## cliff.toml load-bearing rules

Four settings in `cliff.toml` must not be changed without understanding
their effect:

### tag_pattern

```toml
tag_pattern = "^[0-9]{8}-[0-9a-f]{7,40}$"
```

This regex must exactly match the canonical pin-shape regex enforced
across the codebase. Drift causes git-cliff to see no tags and generate
an empty changelog. `scripts/check-cliff-tag-pattern.sh` enforces
parity at commit time; the cross-layer parity set it joins is
`bump-linpeas.sh`, `flake.nix`, `stale-pin-check.yml`,
`release-on-bump.yml`, and `gen-dashboard-data.sh`.

### docs: update changelog skip rule

```toml
{ message = "^docs: update changelog", skip = true },
```

The changelog commit itself carries the subject `docs: update changelog`. Without this skip, each run would include the previous
run's commit in the next release's entry — a self-reference loop that
inflates the changelog with administrative noise.

### PR-merge entry filter

```toml
{ message = "^Merge ", skip = true },
{ message = "^feat.*\\[#[0-9]+\\]", group = "Features" },
# … one rule per type, each requiring the [#N] link …
{ message = ".*", skip = true },
```

`protect-main` forces every change through a pull request, so each
landed change is a merge commit whose subject is the PR title plus
`(#N)` — rewritten to a `[#N]` link by the preprocessor below. Every
group rule requires that link, so only the merge commits are kept; the
trailing catch-all skips the branch commits the merge brought in.
Without this, both the merge commit (linked) and its branch commits
(unlinked) would render, producing duplicate entries for every PR. The
leading `^Merge ` rule skips any commit that uses GitHub's default
`Merge pull request …` subject. Breaking changes are recognized by the
`!` type suffix, per the repo's commit convention.

### PR-number preprocessor

```toml
{ pattern = '\(#([0-9]+)\)', replace = "([#${1}](https://github.com/rvenutolo/linPEAS-flake/pull/${1}))" },
```

Git-cliff runs this preprocessor before any other rule. Commit subjects
that include `(#NNN)` — the format GitHub inserts into merge-commit
subjects — are rewritten to a clickable `[#NNN](…)` link in the
rendered changelog. This preprocessor is the **sole** source of PR
links: rendering a second link (e.g. a body-template `pr_number` block)
would double-link every entry as `([#N](…)) ([#N](…))`.

## Link-duplication guard

`scripts/check-changelog-links.sh` regenerates the changelog from the
flake-pinned `.#git-cliff` into a temp file and asserts two invariants
on the output: zero duplicate *identical* adjacent PR links (a commit
citing two distinct PRs is legitimate and passes), and that the
scorecard-count preprocessor still applies (no `15-check allowlist`
survives). `CHANGELOG.md` is generator-owned and excluded from treefmt
and markdownlint, so this check is the only guard against a malformed
regeneration. It runs offline — git-cliff parses the PR number from the
`(#N)` subject suffix, so no token is needed — as the required
`changelog-links` CI job on every PR.

## Freshness guard

`scripts/check-changelog-fresh.sh` regenerates the changelog from the
flake-pinned `.#git-cliff` and compares its **released** sections (from
the first `## [<tag>]` header onward) against the committed `CHANGELOG.md`.
A release that ships without its changelog update landing — or a manual edit
to a released section — is caught rather than accruing silently.

Only released sections are compared: the `## Unreleased` section
legitimately changes with every merged commit, so diffing it would force a
changelog regen on every PR. When it fails, regenerate and commit:

```sh
nix shell .#git-cliff --command git-cliff --config cliff.toml --output CHANGELOG.md
```

### Release-window exclusion

The release tag is created before the changelog commit that describes it, so
between the two there is a window in which the regenerated changelog carries a
released section that no committed file could yet contain. Comparing it there
reports staleness nothing can fix: `main` goes red, and because
`changelog-links` is a required check, every open PR based before the changelog
commit is blocked on it.

A release tag is therefore compared only when its commit is an ancestor of the
most recent commit that touched `CHANGELOG.md` — only when the changelog was
written at a point where that tag already existed. Newer tags are excluded from
both sides of the comparison. The condition is history-relative rather than
time-based: a wall-clock grace period would either mask a genuinely dropped
changelog or still flake, depending on how it was tuned.

This accepts one blind spot: only tags predating the last `CHANGELOG.md` commit
are covered. A release whose changelog never lands stays uncovered until some
later changelog commit exists, and two releases stacking up inside the window
would exclude both. That is tolerable because a dropped changelog job fails
loudly through the `release-on-bump` notify path — this check is the backstop,
not the primary signal.

The exclusion depends on an ordering property of `release-on-bump.yml`, and
changing that workflow can silently weaken this guard. The release job creates
the tag on the triggering commit (`gh release create --target`), and the
changelog job later cuts its branch from `main`. The tag is therefore always an
ancestor of the changelog commit, so on the changelog pull request's own merge
ref the tag is compared rather than excluded — the exclusion suppresses the
window for unrelated pull requests while never disabling the check on the one
pull request that has to land the section.

Reorder those two steps — tag after the changelog commit, or cut the changelog
branch from the tag instead of from `main` — and the tag stops being an
ancestor. The exclusion would then swallow the very case this guard exists to
catch, on every release, with no test going red. Treat that ordering as part of
this guard's contract rather than an incidental detail of the release workflow.

It runs offline (like the link guard) as part of the required
`changelog-links` CI job, which checks out with `fetch-depth: 0` so every
release tag is visible to git-cliff.

## End-to-end sequence

The changelog job in `release-on-bump.yml` performs these steps in
order:

1. Check out the repo with `fetch-depth: 0` (full history required for
    git-cliff to walk all tags).
1. Mint a short-lived App installation token using
    `BUMP_APP_CLIENT_ID` + `BUMP_APP_PRIVATE_KEY`.
1. Run `nix shell .#git-cliff --command git-cliff --config cliff.toml --output CHANGELOG.md`.
1. Detect whether `CHANGELOG.md` changed (a no-op day — identical pin
    — produces no diff).
1. If changed, create a `chore/changelog-${VERSION}` branch from
    `main` and commit `CHANGELOG.md` via REST `PUT /contents` as the
    App identity (GitHub web-flow-signs the commit).
1. Open a PR against `main` and enable auto-merge
    (`gh pr merge --auto --merge --delete-branch`). The PR lands once
    the `protect-main` required status checks pass.

The PR detour is mandatory: `protect-main` has `bypass_actors == []`
and a `pull_request` rule, so direct `PUT /contents` to `branch=main`
returns `HTTP 409 "Changes must be made through a pull request"`. The
flow mirrors `update-linpeas.yml push-and-merge` exactly.

## Recovery procedures

### Missed entry

A missed changelog entry (changelog job failed or was skipped) can be
recovered by triggering `release-on-bump.yml` via `workflow_dispatch`.
The job re-runs git-cliff over the full tag history and commits the
corrected file.

### File lost entirely

If `CHANGELOG.md` is deleted or corrupted, rebuild it locally:

```sh
nix shell .#git-cliff --command git-cliff \
  --config cliff.toml \
  --output CHANGELOG.md
```

Commit the result with subject `docs: update changelog` so the skip
rule suppresses it from future changelog runs. Then push and verify.
