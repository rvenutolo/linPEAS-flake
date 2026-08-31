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
every push to `main` that changes `linpeas-pin.json` — provided the
`release` job succeeded and the pin's release tag does not already
exist (`tag-exists == 'false'`). It also runs on `workflow_dispatch`
when `force-republish: true` is passed, which overrides the tag-exists
gate; a `backfill-tag` dispatch skips it (see Recovery below). A changelog
failure does not
block image publication — the job depends only on `release`
(`needs: [release]`), so it runs in parallel with the image and manifest
jobs and a transient cliff error cannot prevent the OCI image from
shipping.

## App identity

The changelog commit is pushed using the same `linpeas-flake-bumper`
GitHub App identity that `update-linpeas.yml`'s `push-and-merge` job
uses: `vars.BUMP_APP_CLIENT_ID` + `secrets.BUMP_APP_PRIVATE_KEY`. No new secret
surface is introduced.

## cliff.toml load-bearing rules

Six settings in `cliff.toml` must not be changed without understanding
their effect:

### tag_pattern

```toml
tag_pattern = "^[0-9]{8}-[0-9a-f]{7,40}$"
```

This regex must exactly match the canonical pin-shape regex enforced
across the codebase. Drift causes git-cliff to see no tags and generate
an empty changelog. `scripts/check-cliff-tag-pattern.sh` enforces
parity as the required `cliff-tag-pattern` CI job. The cross-layer
parity set it joins is listed in
[architecture/auto-update.md](../architecture/auto-update.md#canonical-pin-shape),
generated from the tree.

### docs: update changelog skip rule

```toml
{ message = "^docs: update changelog", skip = true },
```

The changelog commit itself carries the subject
`docs: update changelog for <VERSION>`, and the skip rule is anchored to
the `^docs: update changelog` prefix so both that commit and a manual
regeneration are suppressed. Without this skip, each run would include the previous
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

Git-cliff runs the preprocessors before any commit parser, so the
`[#N]` link the group rules require is already in place. Commit subjects
that include `(#NNN)` — the format GitHub inserts into merge-commit
subjects — are rewritten to a clickable `[#NNN](…)` link in the
rendered changelog. This preprocessor is the **sole** source of PR
links: rendering a second link (e.g. a body-template `pr_number` block)
would double-link every entry as `([#N](…)) ([#N](…))`.

### scorecard-count preprocessor

```toml
{ pattern = '15-check allowlist', replace = "10-check allowlist" },
```

Rewrites one mislabeled historical commit subject so the rendered
changelog states the allowlist size that was in force when that commit
landed — deliberately not the current count, since the changelog records
what shipped. The
[link-duplication guard](#link-duplication-guard) below asserts on every
PR that no `15-check allowlist` survives regeneration, so removing this
preprocessor fails the required `changelog-links` job; the replacement
value itself is not pinned by any check.

### spelling preprocessor

```toml
{ pattern = 'unparse[a]ble', replace = "unparsable" },
```

Corrects one merged commit subject whose "unparsable" carries an extra
letter. Merge subjects are frozen in signed history and this one renders
into `CHANGELOG.md`, so render time is the only place the word can be
fixed. `_typos.toml` does not exclude `CHANGELOG.md` and `typos` is a
required check, so removing this preprocessor turns that check red on
the next regeneration. The pattern uses a character class rather than
spelling the misspelled word because the same spell-check scans
`cliff.toml` itself.

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

Exit 1 means an assertion failed. Exit 2 means the check could not run —
git-cliff failed, nix is absent, or `cliff.toml` is missing — so there was
no output to assert on. Chase the generator or its config, not the link
template.

## Freshness guard

`scripts/check-changelog-fresh.sh` regenerates the changelog from the
flake-pinned `.#git-cliff` and compares its **released** sections (from
the first `## [<tag>]` header onward) against the committed `CHANGELOG.md`.
A release that ships without its changelog update landing — or a manual edit
to a released section — is caught rather than accruing silently.

Only released sections are compared: the `## Unreleased` section
legitimately changes with every merged commit, so diffing it would force a
changelog regen on every PR. When it exits 1, regenerate and commit:

```sh
nix shell .#git-cliff --command git-cliff --config cliff.toml --output CHANGELOG.md
```

Exit 2 means something else entirely: the check could not run, so freshness
was never evaluated. Either the generator itself failed, or an input it
reads — `CHANGELOG.md`, `cliff.toml`, nix on `PATH` — was absent. Read the
error on stderr and fix the generator, its config, or the environment —
regenerating is the wrong move, because the committed changelog was never
the subject of the failure. Both changelog checks separate the two codes
for exactly this reason.

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
    git-cliff to walk all tags), then install Nix via
    `./.github/actions/setup-nix`.
1. Mint a short-lived App installation token using
    `vars.BUMP_APP_CLIENT_ID` + `secrets.BUMP_APP_PRIVATE_KEY`.
1. Re-assert the canonical pin shape on `VERSION` at the credential
    boundary, failing the job on a malformed value.
1. Run `nix shell .#git-cliff --command git-cliff --config cliff.toml --output CHANGELOG.md`.
1. Detect whether `CHANGELOG.md` changed (a no-op day — identical pin
    — produces no diff).
1. If changed, render the latest section with `git-cliff --latest --strip header` into `.release-notes.md` for the release body.
1. If changed, create a `chore/changelog-${VERSION}` branch from
    `main` and commit `CHANGELOG.md` via REST `PUT /contents` as the
    App identity (GitHub web-flow-signs the commit).
1. Open a PR against `main` and enable auto-merge
    (`gh pr merge --auto --merge --delete-branch`), then block until
    the PR merges: the wait is bounded, and a closed PR or a stall fails
    the job so `notify` files an issue. The PR lands once the
    `protect-main` required status checks pass.
1. If changed, patch the just-published release's body: build
    `.release-body.md` from `.release-notes.md` plus the upstream
    tracking footer and apply it with
    `gh release edit "${VERSION}" --notes-file .release-body.md`.

The PR detour is mandatory: `protect-main` has `bypass_actors == []`
and a `pull_request` rule, so direct `PUT /contents` to `branch=main`
returns `HTTP 409 "Changes must be made through a pull request"`. The
flow mirrors `update-linpeas.yml push-and-merge`, with one addition:
the changelog job blocks until the PR merges.

## Recovery procedures

### Missed entry

A missed changelog entry (changelog job failed or was skipped) can be
recovered by triggering `release-on-bump.yml` via `workflow_dispatch`
with `force-republish: true`. The input is required: the release tag
already exists on every recovery path, so the job's
`tag-exists == 'false' || force-republish` gate skips it on a bare
dispatch. With the input set, the job re-runs git-cliff over the full
tag history and commits the corrected file.

### File lost entirely

If `CHANGELOG.md` is deleted or corrupted, rebuild it locally:

```sh
nix shell .#git-cliff --command git-cliff \
  --config cliff.toml \
  --output CHANGELOG.md
```

Commit the result with subject `docs: update changelog` so the skip
rule suppresses it from future changelog runs. Then push and verify.
