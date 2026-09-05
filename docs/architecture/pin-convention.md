# Pin convention for GitHub Actions

Every `uses:` reference to a third-party GitHub Action in this repo
is pinned by full 40-hex commit SHA. The trailing comment names a
**versioned tag** (`# vX.Y[.Z]` — at least two numeric components) whose
SHA matches the pin, not the floating major tag; naming the patch tag is
the convention.

```yaml
# Required
- uses: some-org/some-action@0123456789abcdef0123456789abcdef01234567 # v3.36.0

# Forbidden
- uses: some-org/some-action@0123456789abcdef0123456789abcdef01234567 # v3
```

## Why patch tags, not major tags

Major tags are designed to be force-moved on every release, so a
deliberately-moving tag cannot be judged by tag-vs-pin equality.
`ratchet-pin-audit` therefore excludes any ref whose comment names a
floating major (`vN`) from the comparison entirely — a `# vN` comment
removes the ref from audit coverage, leaving its integrity to rest
on the immutable digest pin, Renovate currency, and the PR-time
digest-provenance gate alone.

Per-patch tags (e.g. `v3.36.0`) are immutable by publisher
convention. Anchoring the comment to a patch tag means a future audit
fire is a real signal: the publisher force-moved an immutable tag,
which is a compromise or a maintainer error and warrants escalation
per the ratchet-pin-audit runbook.

## Exceptions

A ref that cannot name a versioned tag carries an inline marker on the
same line: a publisher that tags only majors leaves no versioned tag for
the comment to name, so the comment may remain `# v<major>`; this repo's
own self-referenced composite action names no upstream tag at all (see
Enforcement below). A pin that names the SHA of an annotated tag object
rather than the release commit is a different case: the inventory
script's SHA-equality lookup against `gh api repos/<owner>/<repo>/tags`
returns no match for it, but if its comment names a versioned tag it
needs no marker — the hook's patch-tag regex passes it and the audit
accepts either SHA:

```yaml
- uses: some/action@<sha> # v2 # patch-tag-exception: publisher only tags majors
```

The marker reason must be non-empty (the half that the lint checks) and,
by convention, say why this ref cannot name a versioned tag.

## Enforcement

- Lint: `scripts/check-patch-tag-pins.sh`, wired as the
    `patch-tag-pins` pre-commit hook (see `nix/hooks/workflow-security.nix`).
    Fails the commit locally when a SHA pin lacks both a versioned-tag
    comment and an exception marker — whether the comment is missing
    entirely, names no version, or names only a major tag. The hook is the
    whole enforcement surface: the rule is in no lint group and gates no
    merge, and `harness-group` runs its fixture tests without a live-repo
    probe, so a bypassed hook lets a malformed comment reach `main`.

- Runtime check: [ratchet-pin-audit](../runbooks/ratchet-pin-audit.md)
    (daily). Patch-tag immutability means the audit stays quiet under
    routine publisher releases; a fire is a real upstream tag-move. The
    audit globs `.github/workflows/` only, so a pin inside a composite
    action under `.github/actions/` rests on the PR-time gates alone —
    those do scan both roots.

    The audit compares each pin against the tag it names, accepting a pin
    that equals **either** the annotated-tag-object SHA or the commit that
    tag dereferences to — so a tag-object pin (the form some
    `patch-tag-exception` refs use) is not mistaken for drift, while a
    genuine force-move (which changes both SHAs) still is. Refs whose
    comment names a floating major (`vN`) are excluded from the
    comparison and logged: a deliberately-moving tag cannot be judged by
    tag-vs-pin equality, so their integrity rests on the fallback trio
    under [Why patch tags](#why-patch-tags-not-major-tags); the PR-time
    gate there, `scripts/check-pin-digest-provenance.sh`, requires
    floating-major digest moves to be reachable from the upstream
    default branch.

    Self-reference pins — a `uses:` whose owner/repo is this repo's own —
    are excluded for a different reason: they name no upstream tag at
    all, since Renovate's `pinDigests` rule tracks this repo's own `main`
    HEAD. The digest-provenance gate excludes them too. Both
    self-reference forms are live. The `./`-relative form
    (`uses: ./.github/actions/…`) is content-addressed by the checkout
    itself and skipped by `scripts/check-uses-sha-pinned.sh` as well. The
    `owner/repo@sha` form is what these exclusions actually act on: it is
    used where a `pull_request` event must not run a PR branch's copy of
    the composite, and `scripts/check-uses-sha-pinned.sh` still holds it
    to a full 40-hex SHA at PR time. The `patch-tag-pins` hook reads that
    line too, and since this repo publishes no release tags on its
    composite actions the comment can name no version — so the pin carries
    a `# patch-tag-exception:` marker.

- Bulk remediation: when comment drift is tree-wide,
    `scripts/inventory-action-pin-tags.sh` builds a TSV of each pin's
    resolved tag and `scripts/apply-patch-tag-pin-rewrite.sh` applies
    the recorded rewrites in place — all-or-nothing, aborting on any
    `API_FAILURE` row or a line whose content no longer matches the
    inventory.

- Bump path: Renovate's `helpers:pinGitHubActionDigests` preset.
    Renovate's github-actions manager parses the trailing comment as
    `currentValue` and rewrites both the SHA and the comment on each
    bump, so per-patch comments naturally roll forward to the next
    patch release.
