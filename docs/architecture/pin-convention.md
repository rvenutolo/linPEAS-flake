# Pin convention for GitHub Actions

Every `uses:` reference to a third-party GitHub Action in this repo
is pinned by full 40-hex commit SHA. The trailing comment names the
**exact patch tag** whose SHA matches the pin, not the floating major
tag.

```yaml
# Required
- uses: some-org/some-action@0123456789abcdef0123456789abcdef01234567 # v3.36.0

# Forbidden
- uses: some-org/some-action@0123456789abcdef0123456789abcdef01234567 # v3
```

## Why patch tags, not major tags

Major tags are designed to be force-moved on every release. Pinning
the SHA but commenting against a moving tag means `ratchet-pin-audit`
fires every time a publisher cuts a patch release — pure noise,
indistinguishable from a real force-move.

Per-patch tags (e.g. `v3.36.0`) are immutable by publisher
convention. Anchoring the comment to a patch tag means a future audit
fire is a real signal: the publisher force-moved an immutable tag,
which is a compromise or a maintainer error and warrants escalation
per the ratchet-pin-audit runbook.

## Exceptions

Some publishers tag only majors. Others pin the SHA of an annotated
tag object rather than the release commit, so the inventory script's
SHA-equality lookup against `gh api repos/<owner>/<repo>/tags` returns
no match. For such refs, the comment may remain `# v<major>` (or
`# v<patch>` if that tag already names the exact patch) provided the
same line carries an inline marker:

```yaml
- uses: some/action@<sha> # v2 # patch-tag-exception: publisher only tags majors
```

The marker reason must be non-empty and specific to the ref's
upstream tagging convention.

## Enforcement

- Lint: `scripts/check-patch-tag-pins.sh`, wired as the
    `patch-tag-pins` pre-commit hook (see `nix/hooks/workflow-security.nix`).
    Fails the commit locally when a SHA pin lacks both an exact patch-tag
    comment and an exception marker — whether the comment is missing
    entirely, names no version, or names only a major tag. The hook is the
    whole enforcement surface: the rule is in no lint group and gates no
    merge, and `harness-group` runs its fixture tests without a live-repo
    probe, so a bypassed hook lets a malformed comment reach `main`.

- Runtime check: [ratchet-pin-audit](../runbooks/ratchet-pin-audit.md)
    (daily). Patch-tag immutability means the audit stays quiet under
    routine publisher releases; a fire is a real upstream tag-move.

    The audit compares each pin against the tag it names, accepting a pin
    that equals **either** the annotated-tag-object SHA or the commit that
    tag dereferences to — so a tag-object pin (the form some
    `patch-tag-exception` refs use) is not mistaken for drift, while a
    genuine force-move (which changes both SHAs) still is. Refs whose
    comment names a floating major (`vN`) are excluded from the
    comparison and logged: a deliberately-moving tag cannot be judged by
    tag-vs-pin equality, so their integrity rests on the immutable digest
    pin plus Renovate currency and the PR-time digest-provenance gate
    (`scripts/check-pin-digest-provenance.sh`), which requires
    floating-major digest moves to be reachable from the upstream
    default branch.

- Bump path: Renovate's `helpers:pinGitHubActionDigests` preset.
    Renovate's github-actions manager parses the trailing comment as
    `currentValue` and rewrites both the SHA and the comment on each
    bump, so per-patch comments naturally roll forward to the next
    patch release.
